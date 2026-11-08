#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppInfo : NSObject

+ (instancetype)sharedInfo;
- (instancetype)init __attribute__((unavailable("init is not available")));

@property(nonatomic, readonly) NSString * bundleVersion;
@property(nonatomic, readonly) NSString * buildNumber;
/// The Organic Maps version the build is based on, "2026.10.27-10". The versions come from tools/unix/nogps_version.sh.
@property(nonatomic, readonly) NSString * upstreamVersion;
/// "2026.11.08 (26110807, abcdef12), Organic Maps 2026.10.27-10", with the commit of the build: tells which build it
/// is, in About and the trip log.
@property(nonatomic, readonly) NSString * fullVersion;
@property(nonatomic, readonly) NSString * languageId;
@property(nonatomic, readonly) NSString * twoLetterLanguageId;
@property(nonatomic, readonly) NSString * deviceModel;

@end

NS_ASSUME_NONNULL_END
