// Test-only helper loaded into the fixture. All commands run on AppKit's main
// run loop; no Accessibility, global input injection or screen capture is used.
#import <Cocoa/Cocoa.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>

// Public NSEvent constructors for scroll wheels carry screen coordinates and
// no NSWindow. Supply the logical location when routing a fixture-local wheel.
@interface UIAppKitWheelEvent : NSEvent
@property(strong) NSEvent *scroll;
@property(strong) NSWindow *target;
@property NSPoint point;
@end
@implementation UIAppKitWheelEvent
- (NSEventType)type { return NSEventTypeScrollWheel; }
- (NSPoint)locationInWindow { return self.point; }
- (NSInteger)windowNumber { return self.target.windowNumber; }
- (NSWindow *)window { return self.target; }
- (CGFloat)scrollingDeltaY { return self.scroll.scrollingDeltaY; }
- (BOOL)hasPreciseScrollingDeltas { return self.scroll.hasPreciseScrollingDeltas; }
- (NSEventModifierFlags)modifierFlags { return 0; }
- (NSTimeInterval)timestamp { return self.scroll.timestamp; }
- (CGEventRef)CGEvent { return self.scroll.CGEvent; }
@end

@interface UIAppKitDriver : NSObject
@property int listener;
@property int connection;
@property BOOL pressed;
@property(strong) NSMutableData *input;
@end

@implementation UIAppKitDriver
- (id)command:(NSDictionary *)request {
    NSString *action = request[@"action"];
    if ([action isEqual:@"find"]) {
        for (NSWindow *window in NSApp.windows) {
            // Visibility can precede the window server's activation reply.
            // An inactive window consumes its first mouse-down for activation.
            if (window.visible && window.keyWindow && NSApp.active && [window.title isEqual:request[@"title"]])
                return @(window.windowNumber);
        }
        return NSNull.null;
    }
    NSWindow *window = [NSApp windowWithWindowNumber:[request[@"window"] integerValue]];
    if (!window || !window.visible)
        [NSException raise:@"DriverError" format:@"test window is no longer visible"];
    NSView *view = window.contentView;
    if ([action isEqual:@"size"])
        return @[@((int)view.bounds.size.width), @((int)view.bounds.size.height)];
    if ([action isEqual:@"resize"]) {
        [window setContentSize:NSMakeSize([request[@"width"] doubleValue], [request[@"height"] doubleValue])];
    } else if ([action isEqual:@"close"]) {
        [window performClose:nil];
        self.pressed = NO;
    } else if ([action isEqual:@"refocus"]) {
        // Move key status between real windows, invoking the delegate's native
        // focus notifications without changing another application's windows.
        NSWindow *other = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1, 1)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        other.releasedWhenClosed = NO;
        [other makeKeyAndOrderFront:nil];
        [window makeKeyAndOrderFront:nil];
        [other close];
    } else if ([action isEqual:@"pixel"]) {
        NSRect rect = NSMakeRect([request[@"x"] doubleValue], [request[@"y"] doubleValue], 1, 1);
        NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:rect];
        if (!bitmap) [NSException raise:@"DriverError" format:@"could not cache native view"];
        [view cacheDisplayInRect:rect toBitmapImageRep:bitmap];
        NSColor *color = [[bitmap colorAtX:bitmap.pixelsWide / 2 y:bitmap.pixelsHigh / 2]
            colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        return @(((int)lround(color.redComponent * 255) << 16) |
                 ((int)lround(color.greenComponent * 255) << 8) |
                 (int)lround(color.blueComponent * 255));
    } else if ([action isEqual:@"key"]) {
        NSDictionary *codes = @{@"Tab": @48, @"Return": @36, @"Space": @49};
        NSDictionary *characters = @{@"Tab": @"\t", @"Return": @"\r", @"Space": @" "};
        NSString *name = request[@"name"];
        if (!codes[name]) [NSException raise:@"DriverError" format:@"unknown key %@", name];
        NSEvent *event = [NSEvent keyEventWithType:[request[@"down"] boolValue] ? NSEventTypeKeyDown : NSEventTypeKeyUp
            location:NSZeroPoint modifierFlags:[request[@"shift"] boolValue] ? NSEventModifierFlagShift : 0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
            context:nil characters:characters[name] charactersIgnoringModifiers:characters[name]
            isARepeat:[request[@"repeat"] boolValue] keyCode:[codes[name] unsignedShortValue]];
        [window sendEvent:event];
    } else if ([action isEqual:@"pointer"] || [action isEqual:@"wheel"]) {
        NSPoint point = [view convertPoint:NSMakePoint([request[@"x"] doubleValue], [request[@"y"] doubleValue]) toView:nil];
        NSEvent *event;
        if ([action isEqual:@"wheel"]) {
            CGEventRef scroll = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, -[request[@"steps"] intValue]);
            UIAppKitWheelEvent *wheel = [UIAppKitWheelEvent new];
            wheel.scroll = [NSEvent eventWithCGEvent:scroll];
            wheel.target = window;
            wheel.point = point;
            event = wheel;
            CFRelease(scroll);
        } else {
            NSString *kind = request[@"kind"];
            if ([kind isEqual:@"leave"]) {
                event = [NSEvent enterExitEventWithType:NSEventTypeMouseExited location:point modifierFlags:0
                    timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
                    context:nil eventNumber:0 trackingNumber:0 userData:NULL];
                // Exit events belong to a tracking-area owner, not a hit test.
                [view mouseExited:event];
                return NSNull.null;
            }
            NSEventType type = self.pressed ? NSEventTypeLeftMouseDragged : NSEventTypeMouseMoved;
            if ([kind isEqual:@"down"]) { type = NSEventTypeLeftMouseDown; self.pressed = YES; }
            if ([kind isEqual:@"up"]) { type = NSEventTypeLeftMouseUp; self.pressed = NO; }
            event = [NSEvent mouseEventWithType:type location:point modifierFlags:0
                timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
                context:nil eventNumber:0 clickCount:1 pressure:self.pressed ? 1 : 0];
        }
        [window sendEvent:event];
    } else {
        [NSException raise:@"DriverError" format:@"unknown action %@", action];
    }
    return NSNull.null;
}

- (void)poll:(NSTimer *)timer {
    (void)timer;
    if (self.connection < 0) {
        self.connection = accept(self.listener, NULL, NULL);
        if (self.connection < 0) return;
        fcntl(self.connection, F_SETFL, O_NONBLOCK);
        int enabled = 1;
        setsockopt(self.connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    }
    char bytes[4096];
    ssize_t count = read(self.connection, bytes, sizeof(bytes));
    if (count < 0) return;
    if (count == 0) { close(self.connection); self.connection = -1; return; }
    [self.input appendBytes:bytes length:count];
    while (YES) {
        const char *data = self.input.bytes;
        const char *newline = memchr(data, '\n', self.input.length);
        if (!newline) break;
        NSUInteger length = newline - data;
        NSData *packet = [self.input subdataWithRange:NSMakeRange(0, length)];
        [self.input replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
        NSDictionary *response;
        @try {
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:packet options:0 error:NULL];
            response = @{@"result": [self command:request]};
        } @catch (NSException *error) {
            response = @{@"error": error.reason ?: error.name};
        }
        NSMutableData *reply = [[NSJSONSerialization dataWithJSONObject:response options:0 error:NULL] mutableCopy];
        [reply appendBytes:"\n" length:1];
        if (write(self.connection, reply.bytes, reply.length) != (ssize_t)reply.length) {
            close(self.connection); self.connection = -1; return;
        }
        // Wake the library's event loop so close/resize commands are processed
        // even when no physical desktop event is pending.
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
            modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
    }
}
@end

__attribute__((constructor)) static void install_driver(void) {
    const char *path = getenv("UI_TEST_APPKIT_SOCKET");
    if (!path) return;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (strlen(path) >= sizeof(address.sun_path)) _exit(2);
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 1)) _exit(2);
    fcntl(listener, F_SETFL, O_NONBLOCK);
    @autoreleasepool {
        UIAppKitDriver *driver = [UIAppKitDriver new];
        driver.listener = listener;
        driver.connection = -1;
        driver.input = [NSMutableData data];
        [NSTimer scheduledTimerWithTimeInterval:0.01 target:driver selector:@selector(poll:) userInfo:nil repeats:YES];
    }
}
