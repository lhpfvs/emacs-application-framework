#import <Cocoa/Cocoa.h>

/// A flipped NSView used as the embedding target for a PyQt window.
/// "Flipped" means y=0 is at the top-left, matching Emacs/Qt coordinate convention.
/// Qt's QWindow.fromWinId() on macOS treats the WId as an NSView pointer; reparenting
/// the QWindow into this view embeds the PyQt widget natively inside Emacs.
@interface EAFHostView : NSView
@property (nonatomic, copy) void (^onResize)(int width, int height);
@end
