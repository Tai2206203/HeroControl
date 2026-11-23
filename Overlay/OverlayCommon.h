#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>

// Shared wire format; heartbeat is monotonic, so wall-clock changes do not
// resurrect an old overlay. Neither this protocol nor the HUD accesses a game.
static NSString *HCOverlayNotification(NSString *directory, NSString *action) {
    NSString *home = directory.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    return [NSString stringWithFormat:@"local.herocontrol.overlay.%@.%@", home.lastPathComponent, action];
}

static BOOL HCOverlayPathsValid(NSString *directory, NSString *profile) {
    if (![directory isKindOfClass:NSString.class] || ![profile isKindOfClass:NSString.class]) return NO;
    NSString *home = profile.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSRegularExpression *rule = [NSRegularExpression regularExpressionWithPattern:
        @"^/(private/)?var/mobile/Containers/Data/Application/[0-9A-Fa-f-]{36}$" options:0 error:NULL];
    if ([rule numberOfMatchesInString:home options:0 range:NSMakeRange(0, home.length)] != 1) return NO;
    if (![profile isEqualToString:[home stringByAppendingPathComponent:@"Documents/HeroControl.profile.json"]] ||
        ![directory isEqualToString:[home stringByAppendingPathComponent:@"Library/Caches/HeroOverlay"]]) return NO;
    // Resolve existing parents, rejecting links leading outside this container.
    for (NSString *path in @[directory, profile.stringByDeletingLastPathComponent]) {
        struct stat st = {0};
        if (lstat(path.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || st.st_uid != 501) return NO;
        if (![path.stringByResolvingSymlinksInPath isEqualToString:
              [[home stringByResolvingSymlinksInPath] stringByAppendingPathComponent:
                [path substringFromIndex:home.length + 1]]]) return NO;
    }
    struct stat st = {0};
    return lstat(profile.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == 501;
}

static inline NSDictionary *HCOverlayReadState(NSString *directory) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"state.json"]];
    if (!data || data.length > 32768) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] && [value[@"schemaVersion"] isEqual:@1] ? value : nil;
}

static inline BOOL HCOverlayFresh(NSDictionary *state) {
    id heartbeat = state[@"heartbeat"];
    if (![heartbeat isKindOfClass:NSNumber.class]) return NO;
    double age = NSProcessInfo.processInfo.systemUptime - [heartbeat doubleValue];
    return age >= 0 && age < 6 && [state[@"phase"] isEqual:@"visible"];
}
