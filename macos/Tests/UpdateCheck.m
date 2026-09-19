#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

// Isolated fixture: accepts updates only inside the temporary test application.
@interface UpdateCheck : NSObject <NSApplicationDelegate, SPUUserDriver>
@property SPUUpdater *updater;
@end
@implementation UpdateCheck
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    if ([version isEqualToString:@"2"]) {
        [@"installed and relaunched" writeToFile:[bundle objectForInfoDictionaryKey:@"RelayTestMarker"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NSApp terminate:nil];
        return;
    }
    self.updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:self delegate:nil];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) { NSLog(@"START FAILED: %@", error); exit(1); }
    [self.updater checkForUpdates];
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceInstall); }
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack { NSLog(@"NOT FOUND: %@", error); exit(2); }
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack { NSLog(@"UPDATE FAILED: %@", error); exit(3); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate {}
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack { ack(); }
- (void)dismissUpdateInstallation {}
- (void)showUpdateInFocus {}
@end
int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        UpdateCheck *delegate = [UpdateCheck new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
