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

- (void)didAddSubview:(NSView *)subview {
    [super didAddSubview:subview];
    subview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [subview setFrame:self.bounds];
}

@end
