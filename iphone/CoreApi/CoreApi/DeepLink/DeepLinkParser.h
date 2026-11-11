#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, DeeplinkUrlType) {
  DeeplinkUrlTypeIncorrect = 0,
  DeeplinkUrlTypeMap,
  DeeplinkUrlTypeRoute,
  DeeplinkUrlTypeSearch,
  DeeplinkUrlTypeCrosshair,
  DeeplinkUrlTypeOAuth2,
  DeeplinkUrlTypeMenu,
  DeeplinkUrlTypeSettings
};

@interface DeepLinkParser : NSObject

+ (DeeplinkUrlType)parseAndSetApiURL:(NSURL *)url;
+ (void)executeMapApiRequest;
+ (void)addBookmarksFile:(NSURL *)url isTemporaryFile:(BOOL)isTemporaryFile;
/// Turns a text that another app shares into a URL for parseAndSetApiURL:. Resolves short Google Maps links over the
/// network. The completion runs on the main thread, with nil if the text has no place.
+ (void)resolveSharedText:(NSString *)text completion:(void (^)(NSURL * _Nullable url))completion;

@end

NS_ASSUME_NONNULL_END
