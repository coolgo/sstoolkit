//
//  TWURLConnection.m
//  TWToolkit
//
//  Created by Sam Soffes on 3/19/09.
//  Copyright 2009 Tasteful Works, Inc. All rights reserved.
//

#import "TWURLConnection.h"
#import "NSString+encoding.h"
#import "NSString+SBJSON.h"
#import <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

@implementation TWURLConnection

@synthesize delegate;
@synthesize request;

#pragma mark -
#pragma mark Class Methods
#pragma mark -

+ (BOOL)isConnectedToNetwork {
	
	// Create zero address
	struct sockaddr_in zeroAddress;
	bzero(&zeroAddress, sizeof(zeroAddress));
	zeroAddress.sin_len = sizeof(zeroAddress);
	zeroAddress.sin_family = AF_INET;
	
	// Recover reachability flags
	SCNetworkReachabilityRef defaultRouteReachability = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&zeroAddress);
	SCNetworkReachabilityFlags flags;
	
	BOOL didRetrieveFlags = SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags);
	CFRelease(defaultRouteReachability);
	
	if (!didRetrieveFlags) {
		return NO;
	}
	
	return (didRetrieveFlags && (flags & kSCNetworkFlagsReachable) && !(flags & kSCNetworkFlagsConnectionRequired));
}

#pragma mark -
#pragma mark NSObject
#pragma mark -

- (id)init {
	return [self initWithRequest:nil delegate:nil startImmediately:NO];
}

- (id)initWithDelegate:(id<TWURLConnectionDelegate>)aDelegate {
	return [self initWithRequest:nil delegate:aDelegate startImmediately:NO];
}


- (id)initWithRequest:(TWURLRequest *)aRequest delegate:(id<TWURLConnectionDelegate>)aDelegate {
	return [self initWithRequest:aRequest delegate:aDelegate startImmediately:NO];
}


- (id)initWithRequest:(TWURLRequest *)aRequest delegate:(id<TWURLConnectionDelegate>)aDelegate startImmediately:(BOOL)startImmediately {
	if (self = [super init]) {
		self.delegate = aDelegate;
		request = [aRequest retain];
		_loading = NO;
		
		if (startImmediately) {
			[self start];
		}
	}
	return self;
}


- (id)initWithURL:(NSURL *)aURL delegate:(id<TWURLConnectionDelegate>)aDelegate {
	return [self initWithURL:aURL delegate:aDelegate startImmediately:NO];
}


- (id)initWithURL:(NSURL *)aURL delegate:(id<TWURLConnectionDelegate>)aDelegate startImmediately:(BOOL)startImmediately {
	self = [self initWithRequest:nil delegate:aDelegate startImmediately:NO];
	[self setURL:aURL];
	
	if (startImmediately) {
		[self start];
	}

	return self;
}


- (void)dealloc {
	[self cancel];
	self.delegate = nil;
	[request release];
	request = nil;
	[super dealloc];
}


#pragma mark -
#pragma mark Accessors
#pragma mark -

- (void)setURL:(NSURL *)aURL {
	
	// Don't do anything if request is loading
	if ([self isLoading]) {
		return;
	}
	
	if (!request) {
		request = [[TWURLRequest alloc] initWithURL:aURL];
	} else {
		[request setURL:aURL];
	}
}


- (NSURL *)URL {
	return [request URL];
}


- (BOOL)isLoading {
	return _loading;
}


#pragma mark -
#pragma mark Request Methods
#pragma mark -

- (void)start {
	
	// Cancel any current requests
	[self cancel];
	
	if (request == nil) {
		return;
	}
	
	// Check network
	// TODO: Experienced issues with this, so commenting out for now
//	if ([TWConnection isConnectedToNetwork] == NO) {
//		if ([delegate respondsToSelector:@selector(connection:didFailWithError:)]) {
//			[delegate connection:self failedWithError:nil];
//		}
//		return;
//	}
	
	// Set loading
	_loading = YES;
	
	// Show activity indicator
	[[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
	
	// Initialize the connection
	_urlConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
	
	// Initialize the data
	_receivedData = [[NSMutableData alloc] init];
	
	// Start the request
	[_urlConnection start];
	
	// Notify the delegate the request started
	if ([delegate respondsToSelector:@selector(connection:startedLoadingRequest:)]) {
		[delegate connection:self startedLoadingRequest:request];
	}
}


- (void)cancel {
	[_urlConnection cancel];
	
	// Hide the network activity
	[[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
	
	[_urlConnection release];
	_urlConnection = nil;
	
	[_receivedData release];
	_receivedData = nil;
	
	_loading = NO;
}


#pragma mark -
#pragma mark NSURLConnection Delegate
#pragma mark -

- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	
	NSString *user = [[request URL] user];
	NSString *password = [[request URL] password];
	
	if (user|| password) {
		NSURLCredential *credential = [[NSURLCredential alloc] initWithUser:user password:password persistence:NSURLCredentialPersistenceForSession];
		[[challenge sender] useCredential:credential forAuthenticationChallenge:challenge];
		[credential release];
	} else {
		// Send error to delegate
		if ([delegate respondsToSelector:@selector(connection:didFailWithError:)]) {
			[delegate connection:self failedWithError:nil];
		}
		
		[self cancel];
	}
}


- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	_totalExpectedBytes = [response expectedContentLength];
	[_receivedData setLength:0];
}


- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	[_receivedData appendData:data];
	
	NSInteger receivedBytes = [data length];
	_totalReceivedBytes += receivedBytes;
	
	// Send an update to the delegate
	if ([delegate respondsToSelector:@selector(connection:didReceiveBytes:totalReceivedBytes:totalExpectedBytes:)]) {
		[delegate connection:self didReceiveBytes:receivedBytes totalReceivedBytes:_totalReceivedBytes totalExpectedBytes:_totalExpectedBytes];
	}
	
	// Send chunk to delegate
	if ([delegate respondsToSelector:@selector(connection:didReceiveChunk:)]) {
		NSError *error = nil;
		id parsedChunk = [TWURLConnection parseData:_receivedData dataType:request.dataType error:&error];
		
		// If there was an error parsing the chunk, send the error instead of the parsed chunk
		if (error) {
			if ([delegate respondsToSelector:@selector(connection:failedToParseChunkWithError:)]) {
				[delegate connection:self failedToParseChunkWithError:error];
			}			
			return;
		}
		
		[delegate connection:self didReceiveChunk:parsedChunk];
	}
}


- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	// Send error to delegate
	if ([delegate respondsToSelector:@selector(connection:failedWithError:)]) {
		[delegate connection:self failedWithError:error];
	}
	
	[self cancel];
}


- (void)connectionDidFinishLoading:(NSURLConnection *)connection {

	// Send the result to the delegate
	if ([delegate respondsToSelector:@selector(connection:didFinishLoadingRequest:withResult:)]) {
		
		NSError *error = nil;
		id result = [TWURLConnection parseData:_receivedData dataType:request.dataType error:&error];
		
		// Check for an error parsing the result
		if (error) {
			if ([delegate respondsToSelector:@selector(connection:didFinishLoadingRequest:failedToParseResultWithError:)]) {
				[delegate connection:self didFinishLoadingRequest:request failedToParseResultWithError:error];
			}
			return;
		}
		
		[delegate connection:self didFinishLoadingRequest:request withResult:result];
	}
	
	// Stop request and free up resources
	[self cancel];
}

@end
