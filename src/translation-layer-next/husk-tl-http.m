/* SPDX-License-Identifier: GPL-2.0-or-later */
#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <string.h>

#include "husk-tl-http.h"

#define TL_HTTP_MAX_BODY (64u * 1024u * 1024u)

/* Answering a redirect with nil makes the task finish with the 3xx response itself. */
@interface TLHttpNoRedirect : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSMutableData *received;
@property(nonatomic, strong) NSURLResponse *response;
@property(nonatomic, strong) NSError *failure;
@property(nonatomic, strong) dispatch_semaphore_t done;
@end
@implementation TLHttpNoRedirect
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
        didReceiveResponse:(NSURLResponse *)response
        completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    self.response = response;
    if (response.expectedContentLength > TL_HTTP_MAX_BODY) {
        self.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorDataLengthExceedsMaximum userInfo:nil];
        completionHandler(NSURLSessionResponseCancel);
    } else {
        completionHandler(NSURLSessionResponseAllow);
    }
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    if (self.failure) return;
    if (data.length > TL_HTTP_MAX_BODY - self.received.length) {
        self.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorDataLengthExceedsMaximum userInfo:nil];
        [task cancel];
        return;
    }
    [self.received appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (!self.failure) self.failure = error;
    dispatch_semaphore_signal(self.done);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler
{
    completionHandler(nil);
}
@end

static void put_message(tl_http_response *out, int error, NSString *text)
{
    out->error = error;
    snprintf(out->message, sizeof(out->message), "%s", text.UTF8String ?: "");
}

bool tl_http_perform(const tl_http_request *req, tl_http_response *out)
{
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    if (!req || req->nheaders < 0 || req->nheaders > 128
        || (req->nheaders && (!req->header_names || !req->header_values))
        || req->body_len > TL_HTTP_MAX_BODY || (req->body_len && !req->body)) {
        put_message(out, TL_HTTP_SDK, @"Invalid HTTP request or body limit exceeded");
        return false;
    }
    @autoreleasepool {
        NSURL *url = req->url ? [NSURL URLWithString:@(req->url)] : nil;
        NSString *scheme = url.scheme.lowercaseString;
        if (!url || !url.host.length || (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])) {
            put_message(out, TL_HTTP_MALFORMED_URL, @"Expected an HTTP(S) URL with a host");
            return false;
        }
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
        r.HTTPMethod = req->method && req->method[0] ? @(req->method) : @"GET";
        r.timeoutInterval = req->timeout_ms > 0 ? req->timeout_ms / 1000.0 : 300.0;
        r.HTTPShouldHandleCookies = YES;
        for (int i = 0; i < req->nheaders; i++) {
            if (!req->header_names[i] || !req->header_values[i]) continue;
            [r addValue:@(req->header_values[i]) forHTTPHeaderField:@(req->header_names[i])];
        }
        if (req->body_len > 0) r.HTTPBody = [NSData dataWithBytes:req->body length:req->body_len];

        TLHttpNoRedirect *delegate = [TLHttpNoRedirect new];
        delegate.received = [NSMutableData data];
        delegate.done = dispatch_semaphore_create(0);
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache = nil;
        cfg.timeoutIntervalForResource = 300;
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 1;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:delegate delegateQueue:queue];
        NSURLSessionDataTask *task = [session dataTaskWithRequest:r];
        [task resume];
        dispatch_semaphore_wait(delegate.done, DISPATCH_TIME_FOREVER);
        [session finishTasksAndInvalidate];
        NSData *data = delegate.received;
        NSURLResponse *resp = delegate.response;
        NSError *err = delegate.failure;

        if (err || ![resp isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger code = err.code;
            int kind = TL_HTTP_SDK;
            if (code == NSURLErrorTimedOut) kind = TL_HTTP_TIMEOUT;
            else if (code == NSURLErrorCannotFindHost || code == NSURLErrorDNSLookupFailed) kind = TL_HTTP_UNKNOWN_HOST;
            else if (code == NSURLErrorServerCertificateUntrusted || code == NSURLErrorServerCertificateHasBadDate || code == NSURLErrorServerCertificateHasUnknownRoot
                     || code == NSURLErrorServerCertificateNotYetValid) kind = TL_HTTP_SSL_UNTRUSTED;
            else if (code == NSURLErrorSecureConnectionFailed || code == NSURLErrorClientCertificateRejected) kind = TL_HTTP_SSL;
            else if (code == NSURLErrorNetworkConnectionLost || code == NSURLErrorCannotConnectToHost || code == NSURLErrorNotConnectedToInternet) kind = TL_HTTP_READ;
            put_message(out, kind, err ? err.localizedDescription : @"not an HTTP response");
            return false;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        out->status = (int)http.statusCode;
        NSDictionary *fields = http.allHeaderFields;
        out->header_names = calloc(fields.count + 1, sizeof(char *));
        out->header_values = calloc(fields.count + 1, sizeof(char *));
        if (!out->header_names || !out->header_values) {
            tl_http_response_free(out);
            put_message(out, TL_HTTP_SDK, @"HTTP header allocation failed");
            return false;
        }
        out->header_names[0] = strdup("Status");
        out->header_values[0] = strdup([NSString stringWithFormat:@"HTTP/1.1 %d %@", out->status, [NSHTTPURLResponse localizedStringForStatusCode:http.statusCode]].UTF8String);
        out->nheaders = 1;
        for (id key in fields) {
            NSString *k = [key description], *v = [fields[key] description];
            out->header_names[out->nheaders] = strdup(k.UTF8String ?: "");
            out->header_values[out->nheaders] = strdup(v.UTF8String ?: "");
            out->nheaders++;
        }
        for (int i = 0; i < out->nheaders; i++) {
            if (!out->header_names[i] || !out->header_values[i]) {
                tl_http_response_free(out);
                put_message(out, TL_HTTP_SDK, @"HTTP header allocation failed");
                return false;
            }
        }
        if (data.length) {
            out->body = malloc(data.length);
            if (!out->body) {
                tl_http_response_free(out);
                put_message(out, TL_HTTP_SDK, @"HTTP body allocation failed");
                return false;
            }
            memcpy(out->body, data.bytes, data.length); out->body_len = data.length;
        }
        return true;
    }
}

void tl_http_response_free(tl_http_response *r)
{
    if (!r) return;
    for (int i = 0; i < r->nheaders; i++) { free(r->header_names[i]); free(r->header_values[i]); }
    free(r->header_names); free(r->header_values); free(r->body);
    memset(r, 0, sizeof(*r));
}
