#import "SpectacleAppDelegate.h"

#import <Security/Security.h>
#import <Sparkle/Sparkle.h>

// SecTranslocateIsTranslocatedURL (Security.framework, macOS 10.12+) is not
// declared by the 10.13 SDK headers, so it is declared here; the symbol is
// present in Security.framework on the 10.13 floor (verified against the
// SDK's Security.tbd).
extern Boolean SecTranslocateIsTranslocatedURL(CFURLRef path, bool *isTranslocated, CFErrorRef * __nullable error);

#import "SpectacleAccessibilityElement.h"
#import "SpectacleDefaultShortcutHelpers.h"
#import "SpectacleMigratingShortcutStorage.h"
#import "SpectaclePreferencesController.h"
#import "SpectacleScreenDetector.h"
#import "SpectacleShortcutJSONStorage.h"
#import "SpectacleShortcutManager.h"
#import "SpectacleShortcutTranslations.h"
#import "SpectacleShortcutUserDefaultsStorage.h"
#import "SpectacleUtilities.h"
#import "SpectacleWindowPositionCalculator.h"
#import "SpectacleWindowPositionManager.h"

@implementation SpectacleAppDelegate
{
  NSDictionary<NSString *, NSMenuItem *> *_shortcutMenuItems;
  NSStatusItem *_statusItem;
  id<SpectacleShortcutStorage> _shortcutStorage;
  SpectacleShortcutManager *_shortcutManager;
  SpectacleWindowPositionManager *_windowPositionManager;
  SpectaclePreferencesController *_preferencesController;
  NSTimer *_disableShortcutsForAnHourTimer;
  NSSet<NSString *> *_blacklistedApplications;
  NSMutableSet<NSString *> *_disabledApplications;
  BOOL _shortcutsAreDisabledForAnHour;
  NSSound *_startupSound;
  BOOL _startupSoundPlayed;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
  NSNotificationCenter *workspaceNotificationCenter = [NSWorkspace sharedWorkspace].notificationCenter;
  [notificationCenter addObserver:self
                         selector:@selector(enableStatusItem)
                             name:@"SpectacleStatusItemEnabledNotification"
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(disableStatusItem)
                             name:@"SpectacleStatusItemDisabledNotification"
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(updateShortcutMenuItems)
                             name:@"SpectacleShortcutChangedNotification"
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(updateShortcutMenuItems)
                             name:@"SpectacleRestoreDefaultShortcutsNotification"
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(menuDidSendAction:)
                             name:NSMenuDidSendActionNotification
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(inputSourceSelectionDidChange)
                             name:NSTextInputContextKeyboardSelectionDidChangeNotification
                           object:nil];
  [workspaceNotificationCenter addObserver:self
                                  selector:@selector(applicationDidActivate:)
                                      name:NSWorkspaceDidActivateApplicationNotification
                                    object:nil];
  [workspaceNotificationCenter addObserver:self
                                  selector:@selector(applicationDidDeactivate:)
                                      name:NSWorkspaceDidDeactivateApplicationNotification
                                    object:nil];
  [SpectacleUtilities registerDefaultsForBundle:[NSBundle mainBundle]];
  _shortcutMenuItems = @{
                         @"MoveToCenter": _moveToCenterShortcutMenuItem,
                         @"MoveToFullscreen": _moveToFullscreenShortcutMenuItem,
                         @"MoveToLeftHalf": _moveToLeftShortcutMenuItem,
                         @"MoveToRightHalf": _moveToRightShortcutMenuItem,
                         @"MoveToTopHalf": _moveToTopShortcutMenuItem,
                         @"MoveToBottomHalf": _moveToBottomShortcutMenuItem,
                         @"MoveToUpperLeft": _moveToUpperLeftShortcutMenuItem,
                         @"MoveToLowerLeft": _moveToLowerLeftShortcutMenuItem,
                         @"MoveToUpperRight": _moveToUpperRightShortcutMenuItem,
                         @"MoveToLowerRight": _moveToLowerRightShortcutMenuItem,
                         @"MoveToNextDisplay": _moveToNextDisplayShortcutMenuItem,
                         @"MoveToPreviousDisplay": _moveToPreviousDisplayShortcutMenuItem,
                         @"MoveToNextThird": _moveToNextThirdShortcutMenuItem,
                         @"MoveToPreviousThird": _moveToPreviousThirdShortcutMenuItem,
                         @"MakeLarger": _makeLargerShortcutMenuItem,
                         @"MakeSmaller": _makeSmallerShortcutMenuItem,
                         @"UndoLastMove": _undoLastMoveShortcutMenuItem,
                         @"RedoLastMove": _redoLastMoveShortcutMenuItem,
                         };
  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  _blacklistedApplications = [NSSet setWithArray:[userDefaults objectForKey:@"BlacklistedApplications"]];
  _disabledApplications = [NSMutableSet setWithArray:[userDefaults objectForKey:@"DisabledApplications"]];
  _shortcutStorage = [[SpectacleMigratingShortcutStorage alloc] initWithShortcutStorage:[SpectacleShortcutUserDefaultsStorage new]
                                                                   migrationDestination:[SpectacleShortcutJSONStorage new]];
  _shortcutManager = [[SpectacleShortcutManager alloc] initWithShortcutStorage:_shortcutStorage];
  SpectacleWindowPositionCalculator *windowPositionCalculator = [[SpectacleWindowPositionCalculator alloc] initWithErrorHandler:^(NSString *errorMessage) {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSWarningAlertStyle;
    alert.messageText = @"Encountered an unexpected error";
    alert.informativeText = errorMessage;
    [alert runModal];
  }];
  _windowPositionManager = [[SpectacleWindowPositionManager alloc] initWithScreenDetector:[SpectacleScreenDetector new]
                                                                 windowPositionCalculator:windowPositionCalculator
                                                                          sharedWorkspace:[NSWorkspace sharedWorkspace]];
  _preferencesController = [[SpectaclePreferencesController alloc] initWithShortcutManager:_shortcutManager
                                                                     windowPositionManager:_windowPositionManager
                                                                           shortcutStorage:_shortcutStorage];
  _shortcutsAreDisabledForAnHour = NO;
  [self manageShortcuts];
  [self disableShortcutsIfFrontmostApplicationIsBlacklistedOrDisabled];
  BOOL automaticallyChecksForUpdates = [userDefaults boolForKey:@"AutomaticUpdateCheckEnabled"];
  BOOL statusItemEnabled = [userDefaults boolForKey:@"StatusItemEnabled"];
  if (statusItemEnabled) {
    [self enableStatusItem];
  }
  [[SUUpdater sharedUpdater] setAutomaticallyChecksForUpdates:automaticallyChecksForUpdates];
  [self updateShortcutMenuItems];
  [self installVersionMenuItem];
  [self playStartupSound];
  if ([self runningFromTranslocatedOrNonApplicationsPath]) {
    // A TCC Accessibility grant anchors to the designated requirement of
    // the installed copy; it cannot follow a copy launched from Downloads
    // or from a Gatekeeper-translocated path, so the Accessibility dialog
    // would recur at every launch no matter how often it is granted. Name
    // the actual problem instead of showing the Accessibility dialog. The
    // Accessibility check itself is NOT suppressed, weakened, or bypassed:
    // a correctly installed copy still reaches it unchanged below.
    [self showInstallLocationDialog];
  } else if (!AXIsProcessTrustedWithOptions(NULL)) {
    [[NSApplication sharedApplication] runModalForWindow:self.accessiblityAccessDialogWindow];
  }
}

// YES when this copy is running translocated (Gatekeeper App Translocation
// runs a quarantined app from a randomized read-only path under
// /private/var/folders/.../AppTranslocation/) or from anywhere outside
// /Applications.
- (BOOL)runningFromTranslocatedOrNonApplicationsPath
{
  NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
  if ([bundlePath containsString:@"/AppTranslocation/"]) {
    return YES;
  }
  // SecTranslocateIsTranslocatedURL is available on the 10.13 floor
  // (Security.framework, macOS 10.12+).
  bool translocated = false;
  CFErrorRef translocationError = NULL;
  if (SecTranslocateIsTranslocatedURL((__bridge CFURLRef)[[NSBundle mainBundle] bundleURL], &translocated, &translocationError)
      && translocated) {
    return YES;
  }
  if (translocationError) {
    CFRelease(translocationError);
  }
  if (![bundlePath hasPrefix:@"/Applications/"] && ![bundlePath isEqualToString:@"/Applications/Spectacle.app"]) {
    return YES;
  }
  return NO;
}

// One-time-per-launch dialog naming the install-location problem, with an
// action that reveals the /Applications destination. This misplaced copy
// then quits: it can never hold an Accessibility grant, and running it
// alongside the installed copy would only re-create the confusion.
- (void)showInstallLocationDialog
{
  static BOOL shownThisLaunch = NO;
  if (shownThisLaunch) {
    return;
  }
  shownThisLaunch = YES;
  NSAlert *alert = [NSAlert new];
  alert.alertStyle = NSWarningAlertStyle;
  alert.messageText = @"Spectacle is not running from /Applications";
  alert.informativeText = @"Spectacle must be in /Applications and launched from there. A copy launched from Downloads — or from a temporary translocated path — cannot keep an Accessibility permission grant, so the permission prompt would return at every launch.\n\nMove Spectacle.app into /Applications, then launch the copy there.";
  [alert addButtonWithTitle:@"Show /Applications"];
  [alert addButtonWithTitle:@"Quit"];
  NSModalResponse response = [alert runModal];
  if (response == NSAlertFirstButtonReturn) {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:@"/Applications"]];
  }
  [NSApp terminate:nil];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visibleWindows
{
  [self showPreferencesWindow:self];

  return YES;
}

- (IBAction)showAboutPanel:(id)sender
{
  // SDS-10 10.2 adapted form (10.4.5): the About panel shows the build
  // identifier read from the bundle's own Info.plist at runtime
  // (CFBundleVersion, via SpectacleUtilities.applicationBuildVersion).
  NSString *buildVersion = SpectacleUtilities.applicationBuildVersion;
  NSDictionary<NSString *, id> *options = @{};
  if (buildVersion) {
    options = @{NSAboutPanelOptionVersion: buildVersion};
  }
  [NSApplication.sharedApplication orderFrontStandardAboutPanelWithOptions:options];
}

- (void)installVersionMenuItem
{
  // SDS-10 10.2 adapted form (10.4.5): the build identifier is visible in
  // the status-item menu itself, directly under About Spectacle, read
  // from the bundle's own Info.plist at runtime — never hardcoded.
  NSString *buildVersion = SpectacleUtilities.applicationBuildVersion;
  if (!buildVersion || !_statusItemMenu) {
    return;
  }
  NSMenuItem *versionMenuItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Version %@", buildVersion]
                                                           action:nil
                                                    keyEquivalent:@""];
  versionMenuItem.enabled = NO;
  [_statusItemMenu insertItem:versionMenuItem atIndex:1];
}

- (void)playStartupSound
{
  // SDS-10 10.3 adapted form (10.4.5): Spectacle has no welcome screen,
  // so the standard startup sound plays once at first presentation
  // (application launch). The bundled startup-sound.wav is byte-identical
  // to the Academy library master; a missing asset proceeds silently.
  if (_startupSoundPlayed) {
    return;
  }
  _startupSoundPlayed = YES;
  NSString *soundPath = [NSBundle.mainBundle pathForResource:@"startup-sound" ofType:@"wav"];
  if (!soundPath) {
    return;
  }
  _startupSound = [[NSSound alloc] initWithContentsOfFile:soundPath byReference:YES];
  [_startupSound play];
}

- (IBAction)showPreferencesWindow:(id)sender
{
  [_preferencesController showWindow:sender];
}

- (IBAction)moveFrontmostWindowToFullscreen:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionFullscreen];
}

- (IBAction)moveFrontmostWindowToCenter:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionCenter];
}

- (IBAction)moveFrontmostWindowToLeftHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionLeftHalf];
}

- (IBAction)moveFrontmostWindowToRightHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionRightHalf];
}

- (IBAction)moveFrontmostWindowToTopHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionTopHalf];
}

- (IBAction)moveFrontmostWindowToBottomHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionBottomHalf];
}

- (IBAction)moveFrontmostWindowToUpperLeft:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionUpperLeft];
}

- (IBAction)moveFrontmostWindowToLowerLeft:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionLowerLeft];
}

- (IBAction)moveFrontmostWindowToUpperRight:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionUpperRight];
}

- (IBAction)moveFrontmostWindowToLowerRight:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionLowerRight];
}

- (IBAction)moveFrontmostWindowToNextDisplay:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionNextDisplay];
}

- (IBAction)moveFrontmostWindowToPreviousDisplay:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionPreviousDisplay];
}

- (IBAction)moveFrontmostWindowToNextThird:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionNextThird];
}

- (IBAction)moveFrontmostWindowToPreviousThird:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionPreviousThird];
}

- (IBAction)makeFrontmostWindowLarger:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionLarger];
}

- (IBAction)makeFrontmostWindowSmaller:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionSmaller];
}

- (IBAction)undoLastWindowAction:(id)sender
{
  [_windowPositionManager undoLastWindowAction];
}

- (IBAction)redoLastWindowAction:(id)sender
{
  [_windowPositionManager redoLastWindowAction];
}

- (IBAction)disableOrEnableShortcutsForAnHour:(id)sender
{
  NSInteger newMenuItemState = NSMixedState;
  if (_shortcutsAreDisabledForAnHour) {
    _shortcutsAreDisabledForAnHour = NO;
    [_disableShortcutsForAnHourTimer invalidate];
    [self enableShortcutsIfPermitted];
    newMenuItemState = NSOffState;
  } else {
    _shortcutsAreDisabledForAnHour = YES;
    _disableShortcutsForAnHourTimer = [NSTimer scheduledTimerWithTimeInterval:3600
                                                                       target:self
                                                                     selector:@selector(disableOrEnableShortcutsForAnHour:)
                                                                     userInfo:nil
                                                                      repeats:NO];
    [_shortcutManager unregisterShortcuts];
    newMenuItemState = NSOnState;
  }
  self.disableShortcutsForAnHourMenuItem.state = newMenuItemState;
}

- (IBAction)disableOrEnableShortcutsForApplication:(id)sender
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  if ([_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    [_disabledApplications removeObject:frontmostApplication.bundleIdentifier];
    [self enableShortcutsIfPermitted];
    self.disableShortcutsForApplicationMenuItem.state = NSOffState;
  } else {
    [_disabledApplications addObject:frontmostApplication.bundleIdentifier];
    [_shortcutManager unregisterShortcuts];
    self.disableShortcutsForApplicationMenuItem.state = NSOnState;
  }
  [NSUserDefaults.standardUserDefaults setObject:_disabledApplications.allObjects forKey:@"DisabledApplications"];
}

- (IBAction)openSystemPreferences:(id)sender
{
  NSURL *preferencePaneURL = [NSURL fileURLWithPath:[SpectacleUtilities pathForPreferencePaneNamed:@"Security"]];
  NSBundle *applicationBundle = NSBundle.mainBundle;
  NSURL *scriptURL = [applicationBundle URLForResource:@"Security & Privacy System Preferences" withExtension:@"scpt"];
  [[NSApplication sharedApplication] stopModal];
  [self.accessiblityAccessDialogWindow orderOut:self];
  if (![[[NSAppleScript alloc] initWithContentsOfURL:scriptURL error:nil] executeAndReturnError:nil]) {
    [[NSWorkspace sharedWorkspace] openURL:preferencePaneURL];
  }
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)manageShortcuts
{
  SpectacleShortcutAction action = ^(SpectacleShortcut *shortcut) {
    [self->_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                                      action:shortcut.windowAction];
  };
  NSArray<SpectacleShortcut *> *shortcuts = [_shortcutStorage loadShortcutsWithAction:action];
  if (shortcuts.count != 0) {
    [_shortcutManager manageShortcuts:shortcuts];
  } else {
    [_shortcutManager manageShortcuts:SpectacleDefaultShortcutsWithAction(action)];
  }
}

- (void)enableStatusItem
{
  _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  NSImage *statusImage = [NSBundle.mainBundle imageForResource:@"Spectacle Status Item"];
  [statusImage setTemplate:YES];
  _statusItem.highlightMode = YES;
  _statusItem.image = statusImage;
  _statusItem.menu = _statusItemMenu;
  _statusItem.toolTip = [@"Spectacle " stringByAppendingString:SpectacleUtilities.applicationVersion];
}

- (void)disableStatusItem
{
  [NSStatusBar.systemStatusBar removeStatusItem:_statusItem];
}

- (void)updateShortcutMenuItems
{
  for (NSString *shortcutName in _shortcutMenuItems.allKeys) {
    NSMenuItem *shortcutMenuItem = _shortcutMenuItems[shortcutName];
    SpectacleShortcut *shortcut = [_shortcutManager shortcutForShortcutName:shortcutName];
    if (shortcut) {
      shortcutMenuItem.keyEquivalent = [SpectacleTranslateKeyCode(shortcut.shortcutKeyCode) lowercaseString];
      shortcutMenuItem.keyEquivalentModifierMask = SpectacleConvertModifiersToCocoaIfNecessary(shortcut.shortcutModifiers);
    } else {
      shortcutMenuItem.keyEquivalent = @"";
      shortcutMenuItem.keyEquivalentModifierMask = 0;
    }
  }
}

- (void)enableShortcutsIfPermitted
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  // Do not enable shortcuts if they should remain disabled for an hour.
  if (_shortcutsAreDisabledForAnHour) {
    return;
  }
  // Do not enable shortcuts if the application is blacklisted or disabled.
  if ([_blacklistedApplications containsObject:frontmostApplication.bundleIdentifier]
      || [_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    return;
  }
  [_shortcutManager registerShortcuts];
  [[NSNotificationCenter defaultCenter] postNotificationName:@"SpectacleShortcutChangedNotification" object:self];
}

- (void)disableShortcutsIfFrontmostApplicationIsBlacklistedOrDisabled
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  // Do not disable shortcuts if the application is not blacklisted or disabled.
  if (![_blacklistedApplications containsObject:frontmostApplication.bundleIdentifier]
      && ![_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    return;
  }
  [_shortcutManager unregisterShortcuts];
}

- (void)applicationDidActivate:(NSNotification *)notification
{
  NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
  if ([_blacklistedApplications containsObject:application.bundleIdentifier]
      || [_disabledApplications containsObject:application.bundleIdentifier]) {
    [_shortcutManager unregisterShortcuts];
  }
}

- (void)applicationDidDeactivate:(NSNotification *)notification
{
  NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
  if ([_blacklistedApplications containsObject:application.bundleIdentifier]
      || [_disabledApplications containsObject:application.bundleIdentifier]) {
    [self enableShortcutsIfPermitted];
  }
}

- (void)menuWillOpen:(NSMenu *)menu
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  self.disableShortcutsForApplicationMenuItem.hidden = NO;
  if ([_blacklistedApplications containsObject:frontmostApplication.bundleIdentifier]) {
    self.disableShortcutsForApplicationMenuItem.hidden = YES;
  } else {
    self.disableShortcutsForApplicationMenuItem.title =
      [NSString stringWithFormat:NSLocalizedString(@"MenuItemTitleDisableShortcutsForApplication", @"The menu item title that displays the application to disable shortcuts for"), frontmostApplication.localizedName];
  }
  if ([_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    self.disableShortcutsForApplicationMenuItem.state = NSOnState;
  } else {
    self.disableShortcutsForApplicationMenuItem.state = NSOffState;
  }
}

- (void)menuDidSendAction:(NSNotification *)notification
{
  NSMenuItem *menuItem = notification.userInfo[@"MenuItem"];
  if (menuItem.tag == -1) {
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
  }
}

- (void)inputSourceSelectionDidChange
{
  [_preferencesController loadRegisteredShortcuts];
  [self updateShortcutMenuItems];
}

@end
