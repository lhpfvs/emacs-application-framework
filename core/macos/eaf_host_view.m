#import "eaf_host_view.h"

@implementation EAFHostView

/// Use top-left origin (flipped) so that y coordinates increase downward,
/// matching both Emacs pixel coordinates and Qt's coordinate system.
- (BOOL)isFlipped {
    return YES;
}

/// Accept first responder so embedded Qt events are routed correctly.
- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)layout {
    [super layout];

    if (self.onResize) {
        self.onResize((int)self.bounds.size.width, (int)self.bounds.size.height);
    }
}

@end
