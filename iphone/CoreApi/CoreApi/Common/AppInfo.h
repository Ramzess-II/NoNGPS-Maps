#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppInfo : NSObject

+ (instancetype)sharedInfo;
- (instancetype)init __attribute__((unavailable("init is not available")));

@property(nonatomic, readonly) NSString * bundleVersion;
@property(nonatomic, readonly) NSString * buildNumber;
/// The commit of the build, as `git describe --always --dirty` gives it, from nogps_git_hash.txt that the Run
/// Script phase of OMaps writes.
@property(nonatomic, readonly) NSString * gitHash;
@property(nonatomic, readonly) NSString * languageId;
@property(nonatomic, readonly) NSString * twoLetterLanguageId;
@property(nonatomic, readonly) NSString * deviceModel;

@end

NS_ASSUME_NONNULL_END
