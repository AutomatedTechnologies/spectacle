#import <Cocoa/Cocoa.h>

@interface SpectacleUtilities : NSObject

+ (NSString *)applicationVersion;

+ (NSString *)applicationBuildVersion;

+ (void)registerDefaultsForBundle:(NSBundle *)bundle;

+ (void)displayRunningInBackgroundAlertWithCallback:(void (^)(BOOL, BOOL))callback;
+ (void)displayRestoreDefaultsAlertWithConfirmationCallback:(void (^)(void))callback;

+ (NSString *)pathForPreferencePaneNamed:(NSString *)preferencePaneName;

@end
