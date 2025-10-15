#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import "SnakeGame.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSRect frame = NSMakeRect(0, 0, 800, 600);
    
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    
    [self.window setTitle:@"Metal Snake Game"];
    [self.window center];
    [self.window setAcceptsMouseMovedEvents:YES];
    [self.window setLevel:NSNormalWindowLevel];

    SnakeGame *game = [[SnakeGame alloc] initWithFrame:frame];
    [self.window setContentView:game];
    [self.window makeFirstResponder:game];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeKeyWindow];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
