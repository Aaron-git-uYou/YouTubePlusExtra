#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTKACEOverlayConfigurator)(UIView *overlay, UIStackView *stack);

FOUNDATION_EXPORT void YTKACERegisterOverlayConfigurator(
    NSString *identifier,
    YTKACEOverlayConfigurator configurator
);

FOUNDATION_EXPORT UIButton *YTKACEOverlayButton(
    UIStackView *stack,
    NSString *identifier,
    NSString *symbolName,
    id target,
    SEL action
);

NS_ASSUME_NONNULL_END
