//
//  DZRequestManager.m
//  NetworkByYala
//
//  Created by 文兵 左 on 12/11/15.
//  Copyright © 2015 文兵 左. All rights reserved.
//

#import "DZRequestManager.h"

#define DZ_HTTP_COOKIE_KEY @"DZHTTPCookieKey"

typedef NS_ENUM(NSInteger, DZRequestError) {
    DZRequestErrorOutOfNetwork = 0
};

NSString * const DZRequestOutOfNetwork = @"com.forever.request.outOfNetwork";

@interface DZRequestManager () <NSXMLParserDelegate>

@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;

@property (nonatomic, strong) NSMutableDictionary *requests;

@end

@implementation DZRequestManager

+ (instancetype)shareManager {
    static DZRequestManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - Setter
- (void)setMaxConcurrentRequestCount:(NSInteger)maxConcurrentRequestCount {
    self.sessionManager.operationQueue.maxConcurrentOperationCount = maxConcurrentRequestCount;
}

#pragma mark - Private
- (instancetype)init {
    self = [super init];
    if (self) {
        self.sessionManager = [AFHTTPSessionManager manager];
        self.requests = [NSMutableDictionary dictionary];
        self.maxConcurrentRequestCount = 5;
    }
    return self;
}

- (NSString *)configRequestURL:(DZBaseRequest *)request {
    if ([request.requestURL hasPrefix:@"http"]) {
        return request.requestURL;
    }
    
    if ([request.requestBaseURL hasPrefix:@"http"]) {
        return [NSString stringWithFormat:@"%@%@", request.requestBaseURL, request.requestURL];
    } else {
        DZDebugLog(@"未配置好请求地址 %@ requestURL: %@", request.requestBaseURL, request.requestURL);
        return @"";
    }
}

#pragma mark - cookies
- (void)saveCookies {
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [cookieStorage cookies];
    if (cookies.count > 0) {
        NSData *cookieData = [NSKeyedArchiver archivedDataWithRootObject:cookies];
        
        [[NSUserDefaults standardUserDefaults] setObject:cookieData forKey:DZ_HTTP_COOKIE_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

- (void)loadCookies {
    id cookieData = [[NSUserDefaults standardUserDefaults] objectForKey:DZ_HTTP_COOKIE_KEY];
    if (!cookieData) {
        return;
    }
    NSArray *cookies = [NSKeyedUnarchiver unarchiveObjectWithData:cookieData];
    if ([cookies isKindOfClass:[NSArray class]] && cookies.count > 0) {
        NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (NSHTTPCookie *cookie in cookies) {
            [cookieStorage setCookie:cookie];
        }
    }
}

#pragma mark - 请求结束处理
- (void)requestDidFinishTag:(DZBaseRequest *)request {
    
    if (request.error) {
        if (request.requestFailureBlock) {
            request.requestFailureBlock(request);
        }
        
        if ([request.delegate respondsToSelector:@selector(requestDidFailure:)]) {
            [request.delegate requestDidFailure:request];
        }
        
        [request requestCompleteFailure];
    } else {
        if (request.requestSuccessBlock) {
            request.requestSuccessBlock(request);
        }
        
        if ([request.delegate respondsToSelector:@selector(requestDidSuccess:)]) {
            [request.delegate requestDidSuccess:request];
        }
        
        [request requestCompleteSuccess];
    }
//    [request clearRequestBlock];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DZRequestDidFinishNotification object:request];
    });
}

- (void)handleReponseResult:(NSURLSessionDataTask *)task response:(id)responseObject error:(NSError *)error{
    NSString *key = [self taskHashKey:task];
    DZBaseRequest *request = self.requests[key];
    request.responseObject = responseObject;
    request.error = error;
    
    // 使用cookie时需要保存cookie
    if (request.useCookies) {
        [self saveCookies];
    }
    
    // 发送结束tag
    [self requestDidFinishTag:request];
    
    // 请求成功后移除此次请求
    [self removeRequest:task];
}

- (NSString *)taskHashKey:(NSURLSessionDataTask *)task {
    return [NSString stringWithFormat:@"%lu", (unsigned long)[task hash]];
}

// 管理`request`的生命周期, 防止多线程处理同一key
- (void)addRequest:(DZBaseRequest *)request {
    if (request.task) {
        NSString *key = [self taskHashKey:request.task];
        @synchronized(self) {
            [self.requests setValue:request forKey:key];
        }
    }
}

- (void)removeRequest:(NSURLSessionDataTask *)task {
    NSString *key = [self taskHashKey:task];
    @synchronized(self) {
        [self.requests removeObjectForKey:key];
    }
}

#pragma mark - Public
- (void)startRequest:(DZBaseRequest *)request {
    if (self.reachabilityStatus == DZRequestReachabilityStatusUnknow || self.reachabilityStatus == DZRequestReachabilityStatusNotReachable) {
        NSError *error = [NSError errorWithDomain:DZRequestOutOfNetwork code:DZRequestErrorOutOfNetwork userInfo:nil];
        request.error = error;
        [self requestDidFinishTag:request];
        return;
    }
    
    // 使用cookie
    if (request.useCookies) {
        [self loadCookies];
    }
    
    // 处理URL
    NSString *urlCoded = [self configRequestURL:request];
    NSString *url = [urlCoded stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    if (![DZRequestTool validateUrl:url]) {
        DZDebugLog(@"error in url format：%@", url);
        return;
    }
    
    // 处理参数
    id params = request.requestParameters;
    if (request.requestSerializerType == DZRequestSerializerTypeJSON) {
        if (![NSJSONSerialization isValidJSONObject:params] && params) {
            DZDebugLog(@"error in JSON parameters：%@", params);
            return;
        }
    }
    
    // 处理序列化类型
    DZRequestSerializerType requestSerializerType = request.requestSerializerType;
    switch (requestSerializerType) {
        case DZRequestSerializerTypeForm:
            self.sessionManager.requestSerializer = [AFHTTPRequestSerializer serializer];
            break;
        case DZRequestSerializerTypeJSON:
            self.sessionManager.requestSerializer = [AFJSONRequestSerializer serializer];
        default:
            break;
    }
    self.sessionManager.requestSerializer.timeoutInterval = request.requestTimeoutInterval;
    
    DZResponseSerializerType responseSerializerType = request.responseSerializerType;
    switch (responseSerializerType) {
        case DZResponseSerializerTypeJSON:
            self.sessionManager.responseSerializer = [AFJSONResponseSerializer serializer];
            break;
        case DZResponseSerializerTypeHTTP:
            self.sessionManager.responseSerializer = [AFHTTPResponseSerializer serializer];
            break;
        default:
            break;
    }
    self.sessionManager.responseSerializer.acceptableContentTypes = [NSSet setWithObjects:@"text/html", @"text/xml", @"text/plain", @"text/json", @"text/javascript", @"image/png", @"image/jpeg", @"application/json", nil];
    
    // 处理请求
    DZRequestMethod requestMethod = request.requestMethod;
    NSURLSessionDataTask *task = nil;
    switch (requestMethod) {
        case DZRequestMethodGET:
        {
            task = [self.sessionManager GET:url parameters:params progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
                [self handleReponseResult:task response:responseObject error:nil];
            } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
                [self handleReponseResult:task response:nil error:error];
            }];
            
        }
            break;
        
        case DZRequestMethodPOST:
        {
            if ([request constructionBodyBlock]) {
                task = [self.sessionManager POST:url parameters:params constructingBodyWithBlock:[request constructionBodyBlock] progress:^(NSProgress * _Nonnull uploadProgress) {
                    request.uploadProgress(uploadProgress);
                } success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
                    [self handleReponseResult:task response:responseObject error:nil];
                } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
                    [self handleReponseResult:task response:nil error:error];
                }];
            } else {
                task = [self.sessionManager POST:url parameters:params progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
                    [self handleReponseResult:task response:responseObject error:nil];
                } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
                    [self handleReponseResult:task response:nil error:error];
                }];
            }
        }
            break;
            
        case DZRequestMethodPUT:
        {
            task = [self.sessionManager PUT:url parameters:params success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
                [self handleReponseResult:task response:responseObject error:nil];
            } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
                [self handleReponseResult:task response:nil error:error];
            }];
        }
            break;
        
        case DZRequestMethodDELETE:
        {
            task = [self.sessionManager DELETE:url parameters:params success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
                [self handleReponseResult:task response:responseObject error:nil];
            } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
                [self handleReponseResult:task response:nil error:error];
            }];
        }
            break;
        default:
            break;
    }
    
    [AFNetworkActivityIndicatorManager sharedManager].enabled = YES;
    
    request.task = task;
    [self addRequest:request];
}

- (void)cancelRequest:(DZBaseRequest *)request {
    [request.task cancel];
    [self removeRequest:request.task];
}

- (void)cancelAllRequests {
    for (NSString *key in self.requests) {
        DZBaseRequest *request = self.requests[key];
        [self cancelRequest:request];
    }
}

- (void)startNetworkStateMonitoring {
    [self.sessionManager.reachabilityManager setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {
        switch (status) {
            case AFNetworkReachabilityStatusUnknown:
                _reachabilityStatus = DZRequestReachabilityStatusUnknow;
                break;
            case AFNetworkReachabilityStatusNotReachable:
                _reachabilityStatus = DZRequestReachabilityStatusNotReachable;
                break;
            case AFNetworkReachabilityStatusReachableViaWWAN:
                _reachabilityStatus = DZRequestReachabilityStatusViaWWAN;
                break;
            case AFNetworkReachabilityStatusReachableViaWiFi:
                _reachabilityStatus = DZRequestReachabilityStatusViaWiFi;
                break;
            default:
                break;
        }
    }];
    [self.sessionManager.reachabilityManager startMonitoring];
}

@end
