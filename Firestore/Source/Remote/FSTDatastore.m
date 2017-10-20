/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FSTDatastore.h"

#import <GRPCClient/GRPCCall+OAuth2.h>
#import <GRPCClient/GRPCCall.h>
#import <ProtoRPC/ProtoRPC.h>

#import "FIRFirestore+Internal.h"
#import "FIRFirestoreErrors.h"
#import "FIRFirestoreVersion.h"
#import "FSTAssert.h"
#import "FSTBufferedWriter.h"
#import "FSTClasses.h"
#import "FSTCredentialsProvider.h"
#import "FSTDatabaseID.h"
#import "FSTDatabaseInfo.h"
#import "FSTDispatchQueue.h"
#import "FSTDocument.h"
#import "FSTDocumentKey.h"
#import "FSTExponentialBackoff.h"
#import "FSTLocalStore.h"
#import "FSTLogger.h"
#import "FSTMutation.h"
#import "FSTQueryData.h"
#import "FSTSerializerBeta.h"

#import "Firestore.pbrpc.h"

NS_ASSUME_NONNULL_BEGIN

// GRPC does not publicly declare a means of disabling SSL, which we need for testing. Firestore
// directly exposes an sslEnabled setting so this is required to plumb that through. Note that our
// own tests depend on this working so we'll know if this changes upstream.
@interface GRPCHost
+ (nullable instancetype)hostWithAddress:(NSString *)address;
@property(nonatomic, getter=isSecure) BOOL secure;
@end

/**
 * Initial backoff time in seconds after an error.
 * Set to 1s according to https://cloud.google.com/apis/design/errors.
 */
static const NSTimeInterval kBackoffInitialDelay = 1;
static const NSTimeInterval kBackoffMaxDelay = 60.0;
static const double kBackoffFactor = 1.5;
static NSString *const kXGoogAPIClientHeader = @"x-goog-api-client";
static NSString *const kGoogleCloudResourcePrefix = @"google-cloud-resource-prefix";

/** Function typedef used to create RPCs. */
typedef GRPCProtoCall * (^RPCFactory)(void);

#pragma mark - FSTStream

/** The state of a stream. */
typedef NS_ENUM(NSInteger, FSTStreamState) {
  /**
   * The streaming RPC is not running and there's no error condition. Calling `start` will
   * start the stream immediately without backoff. While in this state -isStarted will return NO.
   */
  FSTStreamStateInitial = 0,

  /**
   * The stream is starting, and is waiting for an auth token to attach to the initial request.
   * While in this state, isStarted will return YES but isOpen will return NO.
   */
  FSTStreamStateAuth,

  /**
   * The streaming RPC is up and running. Requests and responses can flow freely. Both
   * isStarted and isOpen will return YES.
   */
  FSTStreamStateOpen,

  /**
   * The stream encountered an error. The next start attempt will back off. While in this state
   * -isStarted will return NO.
   */
  FSTStreamStateError,

  /**
   * An in-between state after an error where the stream is waiting before re-starting. After
   * waiting is complete, the stream will try to open. While in this state -isStarted will
   * return YES but isOpen will return NO.
   */
  FSTStreamStateBackoff,

  /**
   * The stream has been explicitly stopped; no further events will be emitted.
   */
  FSTStreamStateStopped,
};

// We need to declare these classes first so that Datastore can alloc them.

@interface FSTWatchStream ()

/**
 * Initializes the watch stream with its dependencies.
 */
- (instancetype)initWithDatabase:(FSTDatabaseInfo *)database
             workerDispatchQueue:(FSTDispatchQueue *)workerDispatchQueue
                     credentials:(id<FSTCredentialsProvider>)credentials
                      serializer:(FSTSerializerBeta *)serializer NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithDatabase:(FSTDatabaseInfo *)database
             workerDispatchQueue:(FSTDispatchQueue *)workerDispatchQueue
                     credentials:(id<FSTCredentialsProvider>)credentials
            responseMessageClass:(Class)responseMessageClass NS_UNAVAILABLE;

@end

@interface FSTStream ()

@property(nonatomic, getter=isIdle) BOOL idle;

@end

@interface FSTStream () <GRXWriteable>

@property(nonatomic, strong, readonly) FSTDatabaseInfo *databaseInfo;
@property(nonatomic, strong, readonly) FSTDispatchQueue *workerDispatchQueue;
@property(nonatomic, strong, readonly) id<FSTCredentialsProvider> credentials;
@property(nonatomic, unsafe_unretained, readonly) Class responseMessageClass;
@property(nonatomic, strong, readonly) FSTExponentialBackoff *backoff;

/** A flag tracking whether the stream received a message from the backend. */
@property(nonatomic, assign) BOOL messageReceived;

/**
 * Stream state as exposed to consumers of FSTStream. This differs from GRXWriter's notion of the
 * state of the stream.
 */
@property(nonatomic, assign) FSTStreamState state;

/** The RPC handle. Used for cancellation. */
@property(nonatomic, strong, nullable) GRPCCall *rpc;

/**
 * The send-side of the RPC stream in which to submit requests, but only once the underlying RPC has
 * started.
 */
@property(nonatomic, strong, nullable) FSTBufferedWriter *requestsWriter;

@end

#pragma mark - FSTDatastore

@interface FSTDatastore ()

/** The GRPC service for Firestore. */
@property(nonatomic, strong, readonly) GCFSFirestore *service;

@property(nonatomic, strong, readonly) FSTDispatchQueue *workerDispatchQueue;

/** An object for getting an auth token before each request. */
@property(nonatomic, strong, readonly) id<FSTCredentialsProvider> credentials;

@property(nonatomic, strong, readonly) FSTSerializerBeta *serializer;

@end

@implementation FSTDatastore

+ (instancetype)datastoreWithDatabase:(FSTDatabaseInfo *)databaseInfo
                  workerDispatchQueue:(FSTDispatchQueue *)workerDispatchQueue
                          credentials:(id<FSTCredentialsProvider>)credentials {
  return [[FSTDatastore alloc] initWithDatabaseInfo:databaseInfo
                                workerDispatchQueue:workerDispatchQueue
                                        credentials:credentials];
}

- (instancetype)initWithDatabaseInfo:(FSTDatabaseInfo *)databaseInfo
                 workerDispatchQueue:(FSTDispatchQueue *)workerDispatchQueue
                         credentials:(id<FSTCredentialsProvider>)credentials {
  if (self = [super init]) {
    _databaseInfo = databaseInfo;
    if (!databaseInfo.isSSLEnabled) {
      GRPCHost *hostConfig = [GRPCHost hostWithAddress:databaseInfo.host];
      hostConfig.secure = NO;
    }
    _service = [GCFSFirestore serviceWithHost:databaseInfo.host];
    _workerDispatchQueue = workerDispatchQueue;
    _credentials = credentials;
    _serializer = [[FSTSerializerBeta alloc] initWithDatabaseID:databaseInfo.databaseID];
  }
  return self;
}

- (NSString *)description {
  return [NSString stringWithFormat:@"<FSTDatastore: %@>", self.databaseInfo];
}

/**
 * Converts the error to an error within the domain FIRFirestoreErrorDomain.
 */
+ (NSError *)firestoreErrorForError:(NSError *)error {
  if (!error) {
    return error;
  } else if ([error.domain isEqualToString:FIRFirestoreErrorDomain]) {
    return error;
  } else if ([error.domain isEqualToString:kGRPCErrorDomain]) {
    FSTAssert(error.code >= GRPCErrorCodeCancelled && error.code <= GRPCErrorCodeUnauthenticated,
              @"Unknown GRPC error code: %ld", (long)error.code);
    return
        [NSError errorWithDomain:FIRFirestoreErrorDomain code:error.code userInfo:error.userInfo];
  } else {
    return [NSError errorWithDomain:FIRFirestoreErrorDomain
                               code:FIRFirestoreErrorCodeUnknown
                           userInfo:@{NSUnderlyingErrorKey : error}];
  }
}

+ (BOOL)isAbortedError:(NSError *)error {
  FSTAssert([error.domain isEqualToString:FIRFirestoreErrorDomain],
            @"isAbortedError: only works with errors emitted by FSTDatastore.");
  return error.code == FIRFirestoreErrorCodeAborted;
}

+ (BOOL)isPermanentWriteError:(NSError *)error {
  FSTAssert([error.domain isEqualToString:FIRFirestoreErrorDomain],
            @"isPerminanteWriteError: only works with errors emitted by FSTDatastore.");
  switch (error.code) {
    case FIRFirestoreErrorCodeCancelled:
    case FIRFirestoreErrorCodeUnknown:
    case FIRFirestoreErrorCodeDeadlineExceeded:
    case FIRFirestoreErrorCodeResourceExhausted:
    case FIRFirestoreErrorCodeInternal:
    case FIRFirestoreErrorCodeUnavailable:
    case FIRFirestoreErrorCodeUnauthenticated:
      // Unauthenticated means something went wrong with our token and we need
      // to retry with new credentials which will happen automatically.
      // TODO(b/37325376): Give up after second unauthenticated error.
      return NO;
    case FIRFirestoreErrorCodeInvalidArgument:
    case FIRFirestoreErrorCodeNotFound:
    case FIRFirestoreErrorCodeAlreadyExists:
    case FIRFirestoreErrorCodePermissionDenied:
    case FIRFirestoreErrorCodeFailedPrecondition:
    case FIRFirestoreErrorCodeAborted:
    // Aborted might be retried in some scenarios, but that is dependant on
    // the context and should handled individually by the calling code.
    // See https://cloud.google.com/apis/design/errors
    case FIRFirestoreErrorCodeOutOfRange:
    case FIRFirestoreErrorCodeUnimplemented:
    case FIRFirestoreErrorCodeDataLoss:
    default:
      return YES;
  }
}

/** Returns the string to be used as x-goog-api-client header value. */
+ (NSString *)googAPIClientHeaderValue {
  // TODO(dimond): This should ideally also include the grpc version, however, gRPC defines the
  // version as a macro, so it would be hardcoded based on version we have at compile time of
  // the Firestore library, rather than the version available at runtime/at compile time by the
  // user of the library.
  return [NSString stringWithFormat:@"gl-objc/ fire/%s grpc/", FirebaseFirestoreVersionString];
}

/** Returns the string to be used as google-cloud-resource-prefix header value. */
+ (NSString *)googleCloudResourcePrefixForDatabaseID:(FSTDatabaseID *)databaseID {
  return [NSString
      stringWithFormat:@"projects/%@/databases/%@", databaseID.projectID, databaseID.databaseID];
}
/**
 * Takes a dictionary of (HTTP) response headers and returns the set of whitelisted headers
 * (for logging purposes).
 */
+ (NSDictionary<NSString *, NSString *> *)extractWhiteListedHeaders:
    (NSDictionary<NSString *, NSString *> *)headers {
  NSMutableDictionary<NSString *, NSString *> *whiteListedHeaders =
      [NSMutableDictionary dictionary];
  NSArray<NSString *> *whiteList = @[
    @"date", @"x-google-backends", @"x-google-netmon-label", @"x-google-service",
    @"x-google-gfe-request-trace"
  ];
  [headers
      enumerateKeysAndObjectsUsingBlock:^(NSString *headerName, NSString *headerValue, BOOL *stop) {
        if ([whiteList containsObject:[headerName lowercaseString]]) {
          whiteListedHeaders[headerName] = headerValue;
        }
      }];
  return whiteListedHeaders;
}

/** Logs the (whitelisted) headers returned for an GRPCProtoCall RPC. */
+ (void)logHeadersForRPC:(GRPCProtoCall *)rpc RPCName:(NSString *)rpcName {
  if ([FIRFirestore isLoggingEnabled]) {
    FSTLog(@"RPC %@ returned headers (whitelisted): %@", rpcName,
           [FSTDatastore extractWhiteListedHeaders:rpc.responseHeaders]);
  }
}

- (void)commitMutations:(NSArray<FSTMutation *> *)mutations
             completion:(FSTVoidErrorBlock)completion {
  GCFSCommitRequest *request = [GCFSCommitRequest message];
  request.database = [self.serializer encodedDatabaseID];

  NSMutableArray<GCFSWrite *> *mutationProtos = [NSMutableArray array];
  for (FSTMutation *mutation in mutations) {
    [mutationProtos addObject:[self.serializer encodedMutation:mutation]];
  }
  request.writesArray = mutationProtos;

  RPCFactory rpcFactory = ^GRPCProtoCall * {
    __block GRPCProtoCall *rpc = [self.service
        RPCToCommitWithRequest:request
                       handler:^(GCFSCommitResponse *response, NSError *_Nullable error) {
                         error = [FSTDatastore firestoreErrorForError:error];
                         [self.workerDispatchQueue dispatchAsync:^{
                           FSTLog(@"RPC CommitRequest completed. Error: %@", error);
                           [FSTDatastore logHeadersForRPC:rpc RPCName:@"CommitRequest"];
                           completion(error);
                         }];
                       }];
    return rpc;
  };

  [self invokeRPCWithFactory:rpcFactory errorHandler:completion];
}

- (void)lookupDocuments:(NSArray<FSTDocumentKey *> *)keys
             completion:(FSTVoidMaybeDocumentArrayErrorBlock)completion {
  GCFSBatchGetDocumentsRequest *request = [GCFSBatchGetDocumentsRequest message];
  request.database = [self.serializer encodedDatabaseID];
  for (FSTDocumentKey *key in keys) {
    [request.documentsArray addObject:[self.serializer encodedDocumentKey:key]];
  }

  __block FSTMaybeDocumentDictionary *results =
      [FSTMaybeDocumentDictionary maybeDocumentDictionary];

  RPCFactory rpcFactory = ^GRPCProtoCall * {
    __block GRPCProtoCall *rpc = [self.service
        RPCToBatchGetDocumentsWithRequest:request
                             eventHandler:^(BOOL done,
                                            GCFSBatchGetDocumentsResponse *_Nullable response,
                                            NSError *_Nullable error) {
                               error = [FSTDatastore firestoreErrorForError:error];
                               [self.workerDispatchQueue dispatchAsync:^{
                                 if (error) {
                                   FSTLog(@"RPC BatchGetDocuments completed. Error: %@", error);
                                   [FSTDatastore logHeadersForRPC:rpc RPCName:@"BatchGetDocuments"];
                                   completion(nil, error);
                                   return;
                                 }

                                 if (!done) {
                                   // Streaming response, accumulate result
                                   FSTMaybeDocument *doc =
                                       [self.serializer decodedMaybeDocumentFromBatch:response];
                                   results = [results dictionaryBySettingObject:doc forKey:doc.key];
                                 } else {
                                   // Streaming response is done, call completion
                                   FSTLog(@"RPC BatchGetDocuments completed successfully.");
                                   [FSTDatastore logHeadersForRPC:rpc RPCName:@"BatchGetDocuments"];
                                   FSTAssert(!response, @"Got response after done.");
                                   NSMutableArray<FSTMaybeDocument *> *docs =
                                       [NSMutableArray arrayWithCapacity:keys.count];
                                   for (FSTDocumentKey *key in keys) {
                                     [docs addObject:results[key]];
                                   }
                                   completion(docs, nil);
                                 }
                               }];
                             }];
    return rpc;
  };

  [self invokeRPCWithFactory:rpcFactory
                errorHandler:^(NSError *_Nonnull error) {
                  error = [FSTDatastore firestoreErrorForError:error];
                  completion(nil, error);
                }];
}

- (void)invokeRPCWithFactory:(GRPCProtoCall * (^)(void))rpcFactory
                errorHandler:(FSTVoidErrorBlock)errorHandler {
  // TODO(mikelehen): We should force a refresh if the previous RPC failed due to an expired token,
  // but I'm not sure how to detect that right now. http://b/32762461
  [self.credentials
      getTokenForcingRefresh:NO
                  completion:^(FSTGetTokenResult *_Nullable result, NSError *_Nullable error) {
                    error = [FSTDatastore firestoreErrorForError:error];
                    [self.workerDispatchQueue dispatchAsyncAllowingSameQueue:^{
                      if (error) {
                        errorHandler(error);
                      } else {
                        GRPCProtoCall *rpc = rpcFactory();
                        [FSTDatastore prepareHeadersForRPC:rpc
                                                databaseID:self.databaseInfo.databaseID
                                                     token:result.token];
                        [rpc start];
                      }
                    }];
                  }];
}

- (FSTWatchStream *)createWatchStream {
  return [[FSTWatchStream alloc] initWithDatabase:_databaseInfo
                              workerDispatchQueue:_workerDispatchQueue
                                      credentials:_credentials
                                       serializer:_serializer];
}

- (FSTWriteStream *)createWriteStream {
  return [[FSTWriteStream alloc] initWithDatabase:_databaseInfo
                              workerDispatchQueue:_workerDispatchQueue
                                      credentials:_credentials
                                       serializer:_serializer];
}

/** Adds headers to the RPC including any OAuth access token if provided .*/
+ (void)prepareHeadersForRPC:(GRPCCall *)rpc
                  databaseID:(FSTDatabaseID *)databaseID
                       token:(nullable NSString *)token {
  rpc.oauth2AccessToken = token;
  rpc.requestHeaders[kXGoogAPIClientHeader] = [FSTDatastore googAPIClientHeaderValue];
  // This header is used to improve routing and project isolation by the backend.
  rpc.requestHeaders[kGoogleCloudResourcePrefix] =
      [FSTDatastore googleCloudResourcePrefixForDatabaseID:databaseID];
}

@end

#pragma mark - GRXFilter

/** Filter class that allows disabling of GRPC callbacks. */
@interface GRXFilter : NSObject <GRXWriteable>

- (instancetype)initWithStream:(FSTStream *)stream NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(atomic, readwrite) BOOL passthrough;
@property(nonatomic, weak, readonly) FSTStream *stream;

@end

@implementation GRXFilter

- (instancetype)initWithStream:(FSTStream *)stream {
  if (self = [super init]) {
    _passthrough = YES;
    _stream = stream;
  }
  return self;
}

- (void)writeValue:(id)value {
  if (self.passthrough) {
    [self.stream writeValue:value];
  }
}

- (void)writesFinishedWithError:(NSError *)errorOrNil {
  if (self.passthrough) {
    [self.stream writesFinishedWithError:errorOrNil];
  }
}

@end

#pragma mark - FSTStream

@interface FSTStream ()

@property(nonatomic, strong, readwrite) GRXFilter *grxFilter;

@end

@implementation FSTStream

/** The time a stream stays open after it is marked idle. */
static const NSTimeInterval kIdleTimeout = 60.0;

- (instancetype)initWithDatabase:(FSTDatabaseInfo *)database
             workerDispatchQueue:(FSTDispatchQueue *)workerDispatchQueue
                     credentials:(id<FSTCredentialsProvider>)credentials
            responseMessageClass:(Class)responseMessageClass {
  if (self = [super init]) {
    _databaseInfo = database;
    _workerDispatchQueue = workerDispatchQueue;
    _credentials = credentials;
    _responseMessageClass = responseMessageClass;

    _backoff = [FSTExponentialBackoff exponentialBackoffWithDispatchQueue:workerDispatchQueue
                                                             initialDelay:kBackoffInitialDelay
                                                            backoffFactor:kBackoffFactor
                                                                 maxDelay:kBackoffMaxDelay];
    _state = FSTStreamStateInitial;
  }
  return self;
}

- (BOOL)isStarted {
  [self.workerDispatchQueue verifyIsCurrentQueue];
  FSTStreamState state = self.state;
  return state == FSTStreamStateBackoff || state == FSTStreamStateAuth ||
         state == FSTStreamStateOpen;
}

- (BOOL)isOpen {
  [self.workerDispatchQueue verifyIsCurrentQueue];
  return self.state == FSTStreamStateOpen;
}

- (GRPCCall *)createRPCWithRequestsWriter:(GRXWriter *)requestsWriter {
  @throw FSTAbstractMethodException();  // NOLINT
}

- (void)start:(id)delegate {
  [self.workerDispatchQueue verifyIsCurrentQueue];

  if (self.state == FSTStreamStateError) {
    [self performBackoff:delegate];
    return;
  }

  FSTLog(@"%@ %p start", NSStringFromClass([self class]), (__bridge void *)self);
  FSTAssert(self.state == FSTStreamStateInitial, @"Already started");

  self.state = FSTStreamStateAuth;
  FSTAssert(_delegate == nil, @"Delegate must be nil");
  _delegate = delegate;

  [self.credentials
      getTokenForcingRefresh:NO
                  completion:^(FSTGetTokenResult *_Nullable result, NSError *_Nullable error) {
                    error = [FSTDatastore firestoreErrorForError:error];
                    [self.workerDispatchQueue dispatchAsyncAllowingSameQueue:^{
                      [self resumeStartWithToken:result error:error];
                    }];
                  }];
}

/** Add an access token to our RPC, after obtaining one from the credentials provider. */
- (void)resumeStartWithToken:(FSTGetTokenResult *)token error:(NSError *)error {
  if (self.state == FSTStreamStateStopped) {
    // Streams can be stopped while waiting for authorization.
    return;
  }

  [self.workerDispatchQueue verifyIsCurrentQueue];
  FSTAssert(self.state == FSTStreamStateAuth, @"State should still be auth (was %ld)",
            (long)self.state);

  // TODO(mikelehen): We should force a refresh if the previous RPC failed due to an expired token,
  // but I'm not sure how to detect that right now. http://b/32762461
  if (error) {
    // RPC has not been started yet, so just invoke higher-level close handler.
    [self handleStreamClose:error];
    return;
  }

  self.requestsWriter = [[FSTBufferedWriter alloc] init];
  _rpc = [self createRPCWithRequestsWriter:self.requestsWriter];
  [FSTDatastore prepareHeadersForRPC:_rpc
                          databaseID:self.databaseInfo.databaseID
                               token:token.token];
  FSTAssert(_grxFilter == nil, @"GRX Filter must be nil");
  _grxFilter = [[GRXFilter alloc] initWithStream:self];
  [_rpc startWithWriteable:_grxFilter];

  self.state = FSTStreamStateOpen;
  [self notifyStreamOpen];
}

/** Backs off after an error. */
- (void)performBackoff:(id)delegate {
  FSTLog(@"%@ %p backoff", NSStringFromClass([self class]), (__bridge void *)self);
  [self.workerDispatchQueue verifyIsCurrentQueue];

  FSTAssert(self.state == FSTStreamStateError, @"Should only perform backoff in an error case");
  self.state = FSTStreamStateBackoff;

  FSTWeakify(self);
  [self.backoff backoffAndRunBlock:^{
    FSTStrongify(self);
    [self resumeStartFromBackoff:delegate];
  }];
}

/** Resumes stream start after backing off. */
- (void)resumeStartFromBackoff:(id)delegate {
  if (self.state == FSTStreamStateStopped) {
    // Streams can be stopped while waiting for backoff to complete.
    return;
  }

  // In order to have performed a backoff the stream must have been in an error state just prior
  // to entering the backoff state. If we weren't stopped we must be in the backoff state.
  FSTAssert(self.state == FSTStreamStateBackoff, @"State should still be backoff (was %ld)",
            (long)self.state);

  // Momentarily set state to FSTStreamStateInitial as `start` expects it.
  self.state = FSTStreamStateInitial;
  [self start:delegate];
  FSTAssert([self isStarted], @"Stream should have started.");
}

/**
 * Closes the stream and cleans up as necessary:
 *
 * <ul>
 *   <li>closes the underlying GRPC stream;
 *   <li>calls the onClose handler with the given 'status';
 *   <li>sets internal stream state to 'finalState';
 *   <li>adjusts the backoff timer based on status
 * </ul>
 *
 * A new stream can be opened by calling {@link #start) unless 'finalState' is set to
 * 'State.Stop'.
 *
 * @param finalState the intended state of the stream after closing.
 * @param grpcCode the NSError the connection was closed with.
 */
- (void)close:(FSTStreamState)finalState error:(NSError *_Nullable)error {
  FSTAssert(finalState == FSTStreamStateError || error == nil,
            @"Can't provide an error when not in an error state.");

  [self.workerDispatchQueue verifyIsCurrentQueue];
  [self cancelIdleCheck];

  if (finalState != FSTStreamStateError) {
    // If this is an intentional close ensure we don't delay our next connection attempt.
    [self.backoff reset];
  } else if (error != nil && error.code == FIRFirestoreErrorCodeResourceExhausted) {
    FSTLog(@"%@ %p Using maximum backoff delay to prevent overloading the backend.", [self class],
           (__bridge void *)self);
    [self.backoff resetToMax];
  }

  // This state must be assigned before calling receiveListener.onClose to allow the callback to
  // inhibit backoff or otherwise manipulate the state in its non-started state.
  self.state = finalState;

  if (self.requestsWriter) {
    // Clean up the underlying RPC. If this close: is in response to an error, don't attempt to
    // call half-close to avoid secondary failures.
    if (finalState != FSTStreamStateError) {
      FSTLog(@"%@ %p Closing stream client-side", [self class], (__bridge void *)self);
      @synchronized(self.requestsWriter) {
        [self.requestsWriter finishWithError:nil];
      }
    }
    _requestsWriter = nil;
  }

  // If the caller explicitly requested a stream stop, don't notify them of a closing stream (it
  // could trigger undesirable recovery logic, etc.).
  if (finalState != FSTStreamStateStopped) {
    [self notifyStreamInterrupted:error];
  }

  // Clear the delegates to avoid any possible bleed through of events from GRPC.
  [self.grxFilter setPassthrough:NO];
  _grxFilter = nil;

  FSTAssert(_delegate, @"Delegate should not be nil");
  _delegate = nil;

  // Clean up remaining state.
  _messageReceived = NO;
  _rpc = nil;
}

- (void)stop {
  FSTLog(@"%@ %p stop", NSStringFromClass([self class]), (__bridge void *)self);
  if ([self isStarted]) {
    [self close:FSTStreamStateStopped error:nil];
  }
}

- (void)inhibitBackoff {
  FSTAssert(![self isStarted], @"Can only inhibit backoff after an error (was %ld)",
            (long)self.state);
  [self.workerDispatchQueue verifyIsCurrentQueue];

  // Clear the error condition.
  self.state = FSTStreamStateInitial;
  [self.backoff reset];
}

/** Called by the idle timer when the stream should close due to inactivity. */
- (void)handleIdleCloseTimer {
  [self.workerDispatchQueue verifyIsCurrentQueue];
  if (self.state == FSTStreamStateOpen && [self isIdle]) {
    // When timing out an idle stream there's no reason to force the stream into backoff when
    // it restarts so set the stream state to Initial instead of Error.
    [self close:FSTStreamStateInitial error:nil];
  }
}

- (void)markIdle {
  [self.workerDispatchQueue verifyIsCurrentQueue];
  if (self.state == FSTStreamStateOpen) {
    self.idle = YES;
    [self.workerDispatchQueue dispatchAsyncAllowingSameQueue:^() {
      [self handleIdleCloseTimer];
    }
                                                       after:kIdleTimeout];
  }
}

- (void)cancelIdleCheck {
  [self.workerDispatchQueue verifyIsCurrentQueue];
  self.idle = NO;
}

/**
 * Parses a protocol buffer response from the server. If the message fails to parse, generates
 * an error and closes the stream.
 *
 * @param protoClass A protocol buffer message class object, that responds to parseFromData:error:.
 * @param data The bytes in the response as returned from GRPC.
 * @return An instance of the protocol buffer message, parsed from the data if parsing was
 *     successful, or nil otherwise.
 */
- (nullable id)parseProto:(Class)protoClass data:(NSData *)data error:(NSError **)error {
  NSError *parseError;
  id parsed = [protoClass parseFromData:data error:&parseError];
  if (parsed) {
    *error = nil;
    return parsed;
  } else {
    NSDictionary *info = @{
      NSLocalizedDescriptionKey : @"Unable to parse response from the server",
      NSUnderlyingErrorKey : parseError,
      @"Expected class" : protoClass,
      @"Received value" : data,
    };
    *error = [NSError errorWithDomain:FIRFirestoreErrorDomain
                                 code:FIRFirestoreErrorCodeInternal
                             userInfo:info];
    return nil;
  }
}

/**
 * Writes a request proto into the stream.
 */
- (void)writeRequest:(GPBMessage *)request {
  NSData *data = [request data];

  [self cancelIdleCheck];

  FSTBufferedWriter *requestsWriter = self.requestsWriter;
  @synchronized(requestsWriter) {
    [requestsWriter writeValue:data];
  }
}

#pragma mark Template methods for subclasses

/**
 * Called by the stream after the stream has been successfully connected, authenticated, and is now
 * ready to accept messages.
 *
 * Subclasses should relay to their stream-specific delegate. Calling [super notifyStreamOpen] is
 * not required.
 */
- (void)notifyStreamOpen {
}

/**
 * Called by the stream after the stream has been unexpectedly interrupted, either due to an error
 * or due to idleness.
 *
 * Subclasses should relay to their stream-specific delegate. Calling [super
 * notifyStreamInterrupted] is not required.
 */
- (void)notifyStreamInterrupted:(NSError *_Nullable)error {
}

/**
 * Called by the stream for each incoming protocol message coming from the server.
 *
 * Subclasses should implement this to deserialize the value and relay to their stream-specific
 * delegate, if appropriate. Calling [super handleStreamMessage] is not required.
 */
- (void)handleStreamMessage:(id)value {
}

/**
 * Called by the stream when the underlying RPC has been closed for whatever reason.
 */
- (void)handleStreamClose:(NSError *_Nullable)error {
  FSTLog(@"%@ %p close: %@", NSStringFromClass([self class]), (__bridge void *)self, error);
  FSTAssert([self isStarted], @"Can't handle server close in non-started state.");

  // In theory the stream could close cleanly, however, in our current model we never expect this
  // to happen because if we stop a stream ourselves, this callback will never be called. To
  // prevent cases where we retry without a backoff accidentally, we set the stream to error
  // in all cases.

  [self close:FSTStreamStateError error:error];
}

#pragma mark GRXWriteable implementation
// The GRXWriteable implementation defines the receive side of the RPC stream.

/**
 * Called by GRPC when it publishes a value. It is called from GRPC's own queue so we immediately
 * redispatch back onto our own worker queue.
 */
- (void)writeValue:(id)value __used {
  // TODO(mcg): remove the double-dispatch once GRPCCall at head is released.
  // Once released we can set the responseDispatchQueue property on the GRPCCall and then this
  // method can call handleStreamMessage directly.
  FSTWeakify(self);
  [self.workerDispatchQueue dispatchAsync:^{
    FSTStrongify(self);
    if (!self || self.state == FSTStreamStateStopped) {
      return;
    }
    if (!self.messageReceived) {
      self.messageReceived = YES;
      if ([FIRFirestore isLoggingEnabled]) {
        FSTLog(@"%@ %p headers (whitelisted): %@", NSStringFromClass([self class]),
               (__bridge void *)self,
               [FSTDatastore extractWhiteListedHeaders:self.rpc.responseHeaders]);
      }
    }
    NSError *error;
    id proto = [self parseProto:self.responseMessageClass data:value error:&error];
    if (proto) {
      [self handleStreamMessage:proto];
    } else {
      [_rpc finishWithError:error];
    }
  }];
}

/**
 * Called by GRPC when it closed the stream with an error representing the final state of the
 * stream.
 *
 * Do not call directly, since it dispatches via the worker queue. Call handleStreamClose to
 * directly inform stream-specific logic, or call stop to tear down the stream.
 */
- (void)writesFinishedWithError:(NSError *_Nullable)error __used {
  error = [FSTDatastore firestoreErrorForError:error];
  FSTWeakify(self);
  [self.workerDispatchQueue dispatchAsync:^{
    FSTStrongify(self);
    if (!self || self.state == FSTStreamStateStopped) {
      return;
    }
    [self handleStreamClose:error];
  }];
}

@end

#pragma mark - FSTWatchStream

@interface FSTWatchStream ()

@property(nonatomic, strong, readonly) FSTSerializerBeta *serializer;

@end

@implementation FSTWatchStream

- (instancetype)initWithDatabase:(FSTDatabaseInfo *)database
             workerDispatchQueue:(FSTDispatchQueue *)workerDispatchQueue
                     credentials:(id<FSTCredentialsProvider>)credentials
                      serializer:(FSTSerializerBeta *)serializer {
  self = [super initWithDatabase:database
             workerDispatchQueue:workerDispatchQueue
                     credentials:credentials
            responseMessageClass:[GCFSListenResponse class]];
  if (self) {
    _serializer = serializer;
  }
  return self;
}

- (GRPCCall *)createRPCWithRequestsWriter:(GRXWriter *)requestsWriter {
  return [[GRPCCall alloc] initWithHost:self.databaseInfo.host
                                   path:@"/google.firestore.v1beta1.Firestore/Listen"
                         requestsWriter:requestsWriter];
}

- (void)notifyStreamOpen {
  [self.delegate watchStreamDidOpen];
}

- (void)handleStreamInterrupted:(NSError *_Nullable)error {
  [super handleStreamClose:error];
  [self.delegate watchStreamWasInterrupted:error];
}

- (void)watchQuery:(FSTQueryData *)query {
  FSTAssert([self isOpen], @"Not yet open");
  [self.workerDispatchQueue verifyIsCurrentQueue];

  GCFSListenRequest *request = [GCFSListenRequest message];
  request.database = [_serializer encodedDatabaseID];
  request.addTarget = [_serializer encodedTarget:query];
  request.labels = [_serializer encodedListenRequestLabelsForQueryData:query];

  FSTLog(@"FSTWatchStream %p watch: %@", (__bridge void *)self, request);
  [self writeRequest:request];
}

- (void)unwatchTargetID:(FSTTargetID)targetID {
  FSTAssert([self isOpen], @"Not yet open");
  [self.workerDispatchQueue verifyIsCurrentQueue];

  GCFSListenRequest *request = [GCFSListenRequest message];
  request.database = [_serializer encodedDatabaseID];
  request.removeTarget = targetID;

  FSTLog(@"FSTWatchStream %p unwatch: %@", (__bridge void *)self, request);
  [self writeRequest:request];
}

/**
 * Receives an inbound message from GRPC, deserializes, and then passes that on to the delegate's
 * watchStreamDidChange:snapshotVersion: callback.
 */
- (void)handleStreamMessage:(GCFSListenResponse *)proto {
  FSTLog(@"FSTWatchStream %p response: %@", (__bridge void *)self, proto);
  [self.workerDispatchQueue verifyIsCurrentQueue];

  // A successful response means the stream is healthy.
  [self.backoff reset];

  FSTWatchChange *change = [_serializer decodedWatchChange:proto];
  FSTSnapshotVersion *snap = [_serializer versionFromListenResponse:proto];
  [self.delegate watchStreamDidChange:change snapshotVersion:snap];
}

@end

#pragma mark - FSTWriteStream

@interface FSTWriteStream ()

@property(nonatomic, strong, readonly) FSTSerializerBeta *serializer;

@end

@implementation FSTWriteStream

- (void)start:(id)delegate {
  self.handshakeComplete = NO;
  [super start:delegate];
}

- (instancetype)initWithDatabase:(FSTDatabaseInfo *)database
             workerDispatchQueue:(FSTDispatchQueue *)workerDispatchQueue
                     credentials:(id<FSTCredentialsProvider>)credentials
                      serializer:(FSTSerializerBeta *)serializer {
  self = [super initWithDatabase:database
             workerDispatchQueue:workerDispatchQueue
                     credentials:credentials
            responseMessageClass:[GCFSWriteResponse class]];
  if (self) {
    _serializer = serializer;
  }
  return self;
}

- (GRPCCall *)createRPCWithRequestsWriter:(GRXWriter *)requestsWriter {
  return [[GRPCCall alloc] initWithHost:self.databaseInfo.host
                                   path:@"/google.firestore.v1beta1.Firestore/Write"
                         requestsWriter:requestsWriter];
}

- (void)notifyStreamOpen {
  [self.delegate writeStreamDidOpen];
}

- (void)notifyStreamInterrupted:(NSError *_Nullable)error {
  [self.delegate writeStreamWasInterrupted:error];
}

- (void)writeHandshake {
  // The initial request cannot contain mutations, but must contain a projectID.
  FSTAssert([self isOpen], @"Not yet open");
  FSTAssert(!self.handshakeComplete, @"Handshake sent out of turn");
  [self.workerDispatchQueue verifyIsCurrentQueue];

  GCFSWriteRequest *request = [GCFSWriteRequest message];
  request.database = [_serializer encodedDatabaseID];
  // TODO(dimond): Support stream resumption. We intentionally do not set the stream token on the
  // handshake, ignoring any stream token we might have.

  FSTLog(@"FSTWriteStream %p initial request: %@", (__bridge void *)self, request);
  [self writeRequest:request];
}

- (void)writeMutations:(NSArray<FSTMutation *> *)mutations {
  FSTAssert([self isOpen], @"Not yet open");
  FSTAssert(self.handshakeComplete, @"Mutations sent out of turn");
  [self.workerDispatchQueue verifyIsCurrentQueue];

  NSMutableArray<GCFSWrite *> *protos = [NSMutableArray arrayWithCapacity:mutations.count];
  for (FSTMutation *mutation in mutations) {
    [protos addObject:[_serializer encodedMutation:mutation]];
  };

  GCFSWriteRequest *request = [GCFSWriteRequest message];
  request.writesArray = protos;
  request.streamToken = self.lastStreamToken;

  FSTLog(@"FSTWriteStream %p mutation request: %@", (__bridge void *)self, request);
  [self writeRequest:request];
}

/**
 * Implements GRXWriteable to receive an inbound message from GRPC, deserialize, and then pass
 * that on to the mutationResultsHandler.
 */
- (void)handleStreamMessage:(GCFSWriteResponse *)response {
  FSTLog(@"FSTWriteStream %p response: %@", (__bridge void *)self, response);
  [self.workerDispatchQueue verifyIsCurrentQueue];

  // A successful response means the stream is healthy.
  [self.backoff reset];

  // Always capture the last stream token.
  self.lastStreamToken = response.streamToken;

  if (!self.isHandshakeComplete) {
    // The first response is the handshake response
    self.handshakeComplete = YES;

    [self.delegate writeStreamDidCompleteHandshake];
  } else {
    FSTSnapshotVersion *commitVersion = [_serializer decodedVersion:response.commitTime];
    NSMutableArray<GCFSWriteResult *> *protos = response.writeResultsArray;
    NSMutableArray<FSTMutationResult *> *results = [NSMutableArray arrayWithCapacity:protos.count];
    for (GCFSWriteResult *proto in protos) {
      [results addObject:[_serializer decodedMutationResult:proto]];
    };

    [self.delegate writeStreamDidReceiveResponseWithVersion:commitVersion mutationResults:results];
  }
}

@end

NS_ASSUME_NONNULL_END
