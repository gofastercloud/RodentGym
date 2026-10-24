// See UI.h.

#import "UI.h"

NSView *RGGlassView(NSView *content, CGFloat cornerRadius) {
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:content.frame];
        glass.cornerRadius = cornerRadius;
        content.frame = glass.bounds;
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        glass.contentView = content;
        return glass;
    }
    NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:content.frame];
    v.material = NSVisualEffectMaterialHUDWindow;
    v.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    v.state = NSVisualEffectStateActive;
    v.wantsLayer = YES;
    v.layer.cornerRadius = cornerRadius;
    v.layer.masksToBounds = YES;
    content.frame = v.bounds;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [v addSubview:content];
    return v;
}

void RGSetGlassTint(NSView *glass, NSColor *tint) {
    if (@available(macOS 26.0, *)) {
        if ([glass isKindOfClass:NSGlassEffectView.class]) ((NSGlassEffectView *)glass).tintColor = tint;
    }
}

NSImage *RGSymbol(NSString *name, NSString *description) {
    return [NSImage imageWithSystemSymbolName:name accessibilityDescription:description];
}

NSTextField *RGLabel(NSString *text, NSFont *font, NSColor *colour) {
    NSTextField *t = [NSTextField labelWithString:text];
    t.font = font;
    t.textColor = colour;
    t.drawsBackground = NO;
    t.bezeled = NO;
    t.editable = NO;
    t.selectable = NO;
    return t;
}

void RGDrawText(NSString *text, NSRect rect, NSFont *font, NSColor *colour, NSTextAlignment alignment) {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = alignment;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    [text drawInRect:rect withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: colour,
                                           NSParagraphStyleAttributeName: ps}];
}

void RGDrawCard(NSRect rect, CGFloat radius) {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
    [NSColor.quaternarySystemFillColor setFill];
    [p fill];
    [[NSColor.separatorColor colorWithAlphaComponent:0.6] setStroke];
    p.lineWidth = 0.5;
    [p stroke];
}

void RGDrawLight(NSRect rect, NSString *label, BOOL on, NSColor *onColour) {
    CGFloat r = rect.size.height / 2;
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:r yRadius:r];
    [(on ? onColour : NSColor.tertiarySystemFillColor) setFill];
    [p fill];
    RGDrawText(label, NSMakeRect(rect.origin.x, NSMidY(rect) - 8.5, rect.size.width, 18),
               [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
               on ? NSColor.whiteColor : NSColor.secondaryLabelColor, NSTextAlignmentCenter);
}

BOOL RGReduceMotion(void) {
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

void RGDrawPill(NSRect rect, NSString *label, NSColor *colour) {
    CGFloat r = rect.size.height / 2;
    [[colour colorWithAlphaComponent:0.16] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:r yRadius:r] fill];
    CGFloat d = 7;
    [colour setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(rect.origin.x + 9, NSMidY(rect) - d / 2, d, d)] fill];
    RGDrawText(label, NSMakeRect(rect.origin.x + 21, NSMidY(rect) - 8, rect.size.width - 28, 16),
               [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold], colour, NSTextAlignmentLeft);
}
