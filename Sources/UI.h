// Shared interface helpers: Liquid Glass surfaces (macOS 26+, with a visual-effect fallback),
// SF Symbols, and small drawing utilities that use semantic colours so every view works in
// light mode, dark mode and with Increase Contrast.
//
// MIT License — see LICENSE.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps `content` in a Liquid Glass surface (NSGlassEffectView) on macOS 26 and later, or a
/// HUD-material visual effect view on earlier systems. Use for controls and transient overlays
/// that float above content, never for the content itself.
NSView *RGGlassView(NSView *content, CGFloat cornerRadius);

/// Tints a view returned by RGGlassView (no-op before macOS 26).
void RGSetGlassTint(NSView *glass, NSColor *_Nullable tint);

/// An SF Symbol with an accessibility description.
NSImage *_Nullable RGSymbol(NSString *name, NSString *description);

/// A label suitable for use inside glass: no background, no bezel, not editable.
NSTextField *RGLabel(NSString *text, NSFont *font, NSColor *colour);

/// Draws text truncated to fit `rect`, with the given alignment.
void RGDrawText(NSString *text, NSRect rect, NSFont *font, NSColor *colour, NSTextAlignment alignment);

/// Fills a grouped-content card in the system's quaternary fill with a hairline separator edge.
void RGDrawCard(NSRect rect, CGFloat radius);

/// Draws a capsule status light: tinted when on, a quiet system fill when off.
void RGDrawLight(NSRect rect, NSString *label, BOOL on, NSColor *onColour);

/// YES when the user has asked the system to reduce motion.
BOOL RGReduceMotion(void);

NS_ASSUME_NONNULL_END
