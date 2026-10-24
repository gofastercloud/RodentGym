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

static NSImage *cachedImage(NSView *v) {
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    if (!rep) return nil;
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
    [img addRepresentation:rep];
    return img;
}

static NSView *findSubview(NSView *v, NSString *className) {
    for (NSView *s in v.subviews) {
        if ([NSStringFromClass(s.class) isEqualToString:className]) return s;
        NSView *found = findSubview(s, className);
        if (found) return found;
    }
    return nil;
}

// Table rows are normally made during an on-screen display pass; make the visible ones now.
static void makeTableRows(NSView *v, NSMutableArray<NSTableView *> *found) {
    if ([v isKindOfClass:NSTableView.class]) {
        NSTableView *tv = (NSTableView *)v;
        NSRange rows = [tv rowsInRect:tv.visibleRect];
        for (NSUInteger r = rows.location; r < NSMaxRange(rows); r++) {
            [tv rowViewAtRow:(NSInteger)r makeIfNecessary:YES];
            for (NSInteger c = 0; c < tv.numberOfColumns; c++) [tv viewAtColumn:c row:(NSInteger)r makeIfNecessary:YES];
        }
        [tv layoutSubtreeIfNeeded];
        [found addObject:tv];
    }
    for (NSView *s in v.subviews) makeTableRows(s, found);
}

BOOL RGWriteWindowPNG(NSWindow *window, NSString *path) {
    NSView *frameView = window.contentView.superview ?: window.contentView;
    NSMutableArray<NSTableView *> *tables = [NSMutableArray array];
    makeTableRows(frameView, tables);
    // Selected segments are drawn with a material that doesn't render offscreen
    for (NSToolbarItem *item in window.toolbar.items)
        if ([item.view isKindOfClass:NSSegmentedControl.class]) ((NSSegmentedControl *)item.view).selectedSegment = -1;
    [frameView layoutSubtreeIfNeeded];
    [window display];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    NSRect b = frameView.bounds;
    // The content and the title bar are rendered separately and stacked: rendering the frame view
    // in one pass skips some split-view content offscreen.
    NSView *content = window.contentView, *titlebar = findSubview(frameView, @"NSTitlebarContainerView");
    NSImage *shot = [[NSImage alloc] initWithSize:b.size];
    [shot lockFocusFlipped:NO];
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(NSMakeRect(0, 0, b.size.width, b.size.height));
    NSImage *whole = cachedImage(frameView);
    [whole drawInRect:b];
    if (titlebar && content) {
        NSRect cr = [content convertRect:content.bounds toView:frameView];
        [cachedImage(content) drawInRect:cr];
        // Offscreen, a scroll view doesn't always draw its table; draw the visible part directly
        for (NSTableView *tv in tables) {
            if (tv.isHiddenOrHasHiddenAncestor) continue;
            NSRect vr = NSIntersectionRect(tv.visibleRect, tv.bounds);
            if (NSIsEmptyRect(vr)) continue;
            NSImage *img = cachedImage(tv);
            NSRect from = NSMakeRect(vr.origin.x, tv.bounds.size.height - NSMaxY(vr), vr.size.width, vr.size.height);
            [img drawInRect:[tv convertRect:vr toView:frameView] fromRect:from operation:NSCompositingOperationSourceOver fraction:1];
        }
        NSRect tr = [titlebar convertRect:titlebar.bounds toView:frameView];
        [cachedImage(titlebar) drawInRect:tr];
    }
    [shot unlockFocus];
    if (!whole) return NO;

    CGFloat pad = 60, radius = window.toolbar ? 22 : 16, scale = 2;
    NSSize canvas = NSMakeSize(b.size.width + 2 * pad, b.size.height + 2 * pad);
    NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)(canvas.width * scale) pixelsHigh:(NSInteger)(canvas.height * scale)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    out.size = canvas;
    BOOL dark = [window.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
                == NSAppearanceNameDarkAqua;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:out];
    NSRect wr = NSMakeRect(pad, pad + 8, b.size.width, b.size.height);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:wr xRadius:radius yRadius:radius];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *sh = [NSShadow new];
    sh.shadowColor = [NSColor colorWithWhite:0 alpha:dark ? 0.55 : 0.28];
    sh.shadowBlurRadius = 36;
    sh.shadowOffset = NSMakeSize(0, -14);
    [sh set];
    [NSColor.blackColor setFill];
    [outline fill];
    [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext saveGraphicsState];
    [outline addClip];
    [shot drawInRect:wr fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(wr, 0.25, 0.25) xRadius:radius yRadius:radius];
    edge.lineWidth = 0.5;
    [[NSColor colorWithWhite:dark ? 1 : 0 alpha:dark ? 0.22 : 0.22] setStroke];
    [edge stroke];
    [NSGraphicsContext restoreGraphicsState];
    return [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
