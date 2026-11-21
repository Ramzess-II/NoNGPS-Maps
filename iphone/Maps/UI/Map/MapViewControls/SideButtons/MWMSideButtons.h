#import "MWMMyPositionMode.h"

@interface MWMSideButtons : NSObject

+ (MWMSideButtons *)buttons;

@property(nonatomic) BOOL zoomHidden;
@property(nonatomic) BOOL hidden;
/// The categories button on top, in the navigation only.
@property(nonatomic) BOOL searchShown;
@property(nonatomic, readonly) UIView * view;
/// The panel the balloon of the intro of the first start points at, nil before the map is up. Not `buttons.view`:
/// Swift imports `+buttons` as an initializer and refuses to call it. See NoGpsIntroController.
@property(class, nonatomic, readonly) UIView * introAnchor;

- (instancetype)init __attribute__((unavailable("init is not available")));
- (instancetype)initWithParentView:(UIView *)view;

- (void)processMyPositionStateModeEvent:(MWMMyPositionMode)mode;
/// The search was changed elsewhere: the categories button forgets its category.
- (void)resetSearch;

/// The buttons lie on a panel, the images have no background of their own.
+ (UIImage *)symbol:(NSString *)name;

+ (void)updateAvailableArea:(CGRect)frame;

@end
