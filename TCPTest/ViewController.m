#import "ViewController.h"

#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netinet/tcp.h>

@protocol SocketCallbackHandler <NSObject>

- (void)handleSocketCallback:(nonnull CFSocketRef)socket
                        type:(CFSocketCallBackType)type
                     address:(nullable CFDataRef)address
                        data:(const void* _Nullable)data;

@end

void SocketCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    [(__bridge id<SocketCallbackHandler>)info handleSocketCallback:s type:type address:address data:data];
}

@interface SocketReceiver : NSObject <SocketCallbackHandler, NSStreamDelegate>
@end

@implementation SocketReceiver {
    CFSocketRef _listeningSocket;
    CFRunLoopSourceRef _listeningSocketRunLoopSource;
    
    CFSocketNativeHandle _socket;
    NSInputStream* _socketInputStream;
    NSOutputStream* _socketOutputStream;
    BOOL _socketInputStreamHasBytes;
    
    NSOutputStream* _fileOutputStream;
    BOOL _fileOutputStreamHasSpace;
    
    NSMutableData* _buffer;
}

- (instancetype)initWithFilePath:(NSString*)path {
    if (self = [super init]) {
        _socket = -1;
        
        _buffer = [NSMutableData data];
        
        _fileOutputStream = [NSOutputStream outputStreamToFileAtPath:path append:NO];
        _fileOutputStream.delegate = self;
        [_fileOutputStream scheduleInRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        [_fileOutputStream open];
        
        [self listen];
    }
    return self;
}

- (void)connect:(NSString*)address {
    NSArray<NSString*>* addressComponents = [address componentsSeparatedByString:@":"];
    
    NSInputStream* inputStream;
    NSOutputStream* outputStream;
    [NSStream getStreamsToHostWithName:addressComponents.firstObject
                                  port:addressComponents.lastObject.integerValue
                           inputStream:&inputStream
                          outputStream:&outputStream];
    _socketInputStream = inputStream;
    _socketOutputStream = outputStream;
    
    NSAssert(_socketInputStream != nil, @"");
    NSAssert(_socketOutputStream != nil, @"");
    
    [self openSocketStreams];
}

- (NSInteger)listen {
    CFSocketContext context = {
        .version = 0,
        .info = (__bridge void*)self,
        .retain = NULL,
        .release = NULL,
        .copyDescription = NULL
    };
    _listeningSocket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, SocketCallback, &context);
    NSAssert(_listeningSocket, @"Failed to create listening socket");
    
    CFSocketNativeHandle nativeListeningSocket = CFSocketGetNative(_listeningSocket);
    int const trueValue = 1;
    int status = setsockopt(nativeListeningSocket, SOL_SOCKET, SO_REUSEADDR, &trueValue, sizeof(trueValue));
    NSAssert(status == 0, @"Failed to set SO_REUSEADDR on istening socket (%s)", strerror(errno));
    
    struct sockaddr_in address = { 0 };
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(0);
    address.sin_addr.s_addr = INADDR_ANY;
    CFSocketError error = CFSocketSetAddress(_listeningSocket, (__bridge CFDataRef)[NSData dataWithBytes:&address length:sizeof(address)]);
    NSAssert(error == kCFSocketSuccess, @"Error: %d", (int)error);
    
    socklen_t addressSize = sizeof(address);
    status = getsockname(nativeListeningSocket, (struct sockaddr*)&address, &addressSize);
    NSAssert(status == 0, @"getsockname failed: %s", strerror(errno));
    
    NSInteger port = ntohs(address.sin_port);
    
    _listeningSocketRunLoopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _listeningSocket, 0);
    NSAssert(_listeningSocketRunLoopSource, @"Failed to create runloop source for listening socket!");
    
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _listeningSocketRunLoopSource, kCFRunLoopCommonModes);
    
    return port;
}

- (void)handleSocketCallback:(CFSocketRef)socket type:(CFSocketCallBackType)type address:(CFDataRef)address data:(const void *)data {
    if (socket == _listeningSocket) {
        if (type & kCFSocketAcceptCallBack) {
            NSLog(@"Accepted");
            
            _socket = *(CFSocketNativeHandle const*)data;
            
            CFReadStreamRef inputStream;
            CFWriteStreamRef outputStream;
            CFStreamCreatePairWithSocket(kCFAllocatorDefault, _socket, &inputStream, &outputStream);
            _socketInputStream = (__bridge_transfer NSInputStream*)inputStream;
            _socketOutputStream = (__bridge_transfer NSOutputStream*)outputStream;
            
            [self openSocketStreams];
        } else {
            NSAssert(NO, @"Unknown callback type: %d", (int)type);
        }
    } else {
        NSAssert(NO, @"Unknown socket!");
    }
}

- (void)openSocketStreams {
    _socketInputStream.delegate = self;
    _socketOutputStream.delegate = self;
    
    [_socketInputStream scheduleInRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    [_socketOutputStream scheduleInRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    
    [_socketInputStream open];
    [_socketOutputStream open];
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    switch (eventCode) {
        case NSStreamEventNone: {} break;
        case NSStreamEventOpenCompleted: {
            NSLog(@"Opened: %@", aStream);
        } break;
        case NSStreamEventHasBytesAvailable: {
            if (aStream == _socketInputStream) {
                _socketInputStreamHasBytes = YES;
                [self receive];
            }
        } break;
        case NSStreamEventHasSpaceAvailable: {
            if (aStream == _fileOutputStream) {
                _fileOutputStreamHasSpace = YES;
                [self receive];
            }
        } break;
        case NSStreamEventErrorOccurred: {
            NSLog(@"Stream: %@\nError: %@", aStream, aStream.streamError);
            [self close];
        } break;
        case NSStreamEventEndEncountered: {
            if (aStream == _socketInputStream) {
                NSLog(@"EOF");
                [self close];
            }
        } break;
        default: {
            NSAssert(NO, @"Unknown event: %d", (int)eventCode);
        } break;
    }
}

- (void)receive {
    if (_buffer.length == 0) {
        if (_socketInputStreamHasBytes) {
            _socketInputStreamHasBytes = NO;
            int const maxLength = 1024 * 64;
            _buffer.length += maxLength;
            NSInteger bytesRead = [_socketInputStream read:(uint8_t*)_buffer.mutableBytes + _buffer.length - maxLength maxLength:maxLength];
            if (bytesRead >= 0) {
                _buffer.length -= maxLength - bytesRead;
            }
        }
    }
    if (_buffer.length > 0) {
        if (_fileOutputStreamHasSpace) {
            _fileOutputStreamHasSpace = NO;
            NSInteger bytesWritten = [_fileOutputStream write:_buffer.bytes maxLength:_buffer.length];
            if (bytesWritten > 0) {
                _buffer = [[_buffer subdataWithRange:NSMakeRange(bytesWritten, _buffer.length - bytesWritten)] mutableCopy];
            }
        }
    }
}

- (void)dealloc {
    [self close];
}

- (void)close {
    if (_socketInputStream != nil) {
        [_socketInputStream close];
        _socketInputStream = nil;
    }
    
    if (_socketOutputStream != nil) {
        [_socketOutputStream close];
        _socketOutputStream = nil;
    }
    
    if (_socket != -1) {
        close(_socket);
        _socket = -1;
    }
    
    if (_listeningSocketRunLoopSource != NULL) {
        CFRunLoopSourceInvalidate(_listeningSocketRunLoopSource);
        CFRelease(_listeningSocketRunLoopSource);
        _listeningSocketRunLoopSource = NULL;
    }
    
    if (_listeningSocket != NULL) {
        CFSocketInvalidate(_listeningSocket);
        CFRelease(_listeningSocket);
        _listeningSocket = NULL;
    }
    
    if (_fileOutputStream != nil) {
        [_fileOutputStream close];
        _fileOutputStream = nil;
    }
}

@end

static NSDictionary<NSString*,NSString*>* getIPv4Interfaces() {
    struct ifaddrs* addresses = NULL;
    int status = getifaddrs(&addresses);
    NSCAssert(status == 0, @"Failed to get interface addresses (%s)", strerror(errno));
    
    NSMutableDictionary<NSString*,NSString*>* ipv4Interfaces = [NSMutableDictionary new];
    for (struct ifaddrs* address = addresses; address != NULL; address = address->ifa_next) {
        if (address->ifa_addr != NULL &&
            address->ifa_addr->sa_family == AF_INET) {
            struct sockaddr_in const * ipAddress = (struct sockaddr_in*)address->ifa_addr;
            NSString* ipString = [NSString stringWithCString:inet_ntoa(ipAddress->sin_addr) encoding:NSUTF8StringEncoding];
            ipv4Interfaces[[NSString stringWithCString:address->ifa_name encoding:NSUTF8StringEncoding]] = ipString;
        }
    }
    
    if (addresses != NULL) {
        freeifaddrs(addresses);
    }
    
    return ipv4Interfaces;
}

@interface ViewController ()

@property (nonatomic, weak) IBOutlet UITextField* addressTextField;

@end

@implementation ViewController {
    SocketReceiver* _socketReceiver;
}

- (void)setupReceiver {
    NSString* documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0].path;
    
    if (_socketReceiver != nil) {
        [_socketReceiver close];
    }
    _socketReceiver = [[SocketReceiver alloc] initWithFilePath:[documents stringByAppendingPathComponent:@"received"]];
}

- (IBAction)listen:(id)sender {
    [self setupReceiver];
    NSInteger port = [_socketReceiver listen];
    self.addressTextField.text = [getIPv4Interfaces()[@"en0"] stringByAppendingFormat:@":%d", (int)port];
}

- (IBAction)connect:(id)sender {
    [self setupReceiver];
    [_socketReceiver connect:self.addressTextField.text];
}

@end
