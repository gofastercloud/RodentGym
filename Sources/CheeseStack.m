// Cheese Stack — see CheeseStack.h.
//
// Controls: pointer steers · left click rotates ↺ · right click rotates ↻ · scroll soft-drops ·
// a fast flick (or middle click) slams the piece down. Keyboard: ← → move, ↑/X ↻, Z ↺, ↓ soft drop,
// Space hard drop, P pause.

#import "CheeseStack.h"
#import "UI.h"

#define COLS 10
#define ROWS 20
#define CELL 26.0
#define PAD 20.0
#define BOARD_W (COLS * CELL)
#define BOARD_H (ROWS * CELL)
#define PANEL_X (PAD + BOARD_W + 26)
#define PANEL_W 206.0
#define WIN_W (PANEL_X + PANEL_W + PAD)
#define WIN_H (PAD * 2 + BOARD_H)

typedef struct { int x, y; } RGPt;

// Shapes in their spawn orientation, inside a 4×4 (I) or 3×3 box; y grows downwards.
static const RGPt kShapes[7][4] = {
    {{0, 1}, {1, 1}, {2, 1}, {3, 1}},   // I
    {{1, 0}, {2, 0}, {1, 1}, {2, 1}},   // O
    {{1, 0}, {0, 1}, {1, 1}, {2, 1}},   // T
    {{1, 0}, {2, 0}, {0, 1}, {1, 1}},   // S
    {{0, 0}, {1, 0}, {1, 1}, {2, 1}},   // Z
    {{0, 0}, {0, 1}, {1, 1}, {2, 1}},   // J
    {{2, 0}, {0, 1}, {1, 1}, {2, 1}},   // L
};

static NSString *const kCheeseNames[7] = {@"Swiss", @"Cheddar", @"Brie", @"Gouda", @"Red Leicester", @"Blue", @"Colby"};
static const CGFloat kCheeseRGB[7][3] = {
    {1.00, 0.88, 0.45}, {1.00, 0.64, 0.18}, {0.97, 0.93, 0.76}, {0.92, 0.72, 0.27},
    {0.93, 0.47, 0.17}, {0.80, 0.86, 0.83}, {1.00, 0.78, 0.42}};
static const long kLineScores[5] = {0, 100, 300, 500, 800};
static NSString *const kBestKey = @"CheeseStackBest";

static NSColor *cheese(int t, CGFloat a) {
    return [NSColor colorWithSRGBRed:kCheeseRGB[t][0] green:kCheeseRGB[t][1] blue:kCheeseRGB[t][2] alpha:a];
}

static void label(NSString *s, CGFloat x, CGFloat y, NSFont *f, NSColor *c) {
    [s drawAtPoint:NSMakePoint(x, y) withAttributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: c}];
}

// One block of cheese: a rounded wedge with a highlight and a couple of holes.
static void drawCheese(NSRect r, int type, unsigned seed, CGFloat alpha) {
    NSRect b = NSInsetRect(r, 1, 1);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:b xRadius:4.5 yRadius:4.5];
    NSColor *base = cheese(type, alpha);
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[base blendedColorWithFraction:0.35 ofColor:NSColor.whiteColor]
                                                  endingColor:[base blendedColorWithFraction:0.18 ofColor:NSColor.blackColor]];
    [g drawInBezierPath:p angle:90];   // view is flipped: light at the top
    [[[base blendedColorWithFraction:0.45 ofColor:NSColor.blackColor] colorWithAlphaComponent:0.55 * alpha] setStroke];
    p.lineWidth = 1;
    [p stroke];
    NSColor *hole = [[base blendedColorWithFraction:0.42 ofColor:NSColor.blackColor] colorWithAlphaComponent:0.45 * alpha];
    [hole setFill];
    unsigned h = seed * 2654435761u;
    int holes = 1 + (int)(h % 2);
    for (int i = 0; i < holes; i++) {
        unsigned v = h >> (i * 9);
        CGFloat d = 4 + (v % 4);
        CGFloat hx = b.origin.x + 4 + (v % 13) * (b.size.width - 8 - d) / 12.0;
        CGFloat hy = b.origin.y + 4 + ((v >> 4) % 13) * (b.size.height - 8 - d) / 12.0;
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(hx, hy, d, d)] fill];
    }
}

#pragma mark - Game state

@class RGStackView;

@interface RGCheeseStack () {
@public
    int board[ROWS][COLS];   // 0 empty, otherwise piece type + 1
    int type, nextType, px, py;
    RGPt cells[4];
    long score, lines, level, best;
    long leftClicks, rightClicks, scrollDrops, slams, dropsAtStart;
    BOOL over, paused, started, frozen;   // frozen: demo scene for screenshots
    double gravityAcc, lastTick, flashLeft, flashRight, flashSlam, clearFlashUntil, lastSlam;
    int clearedRows[4], clearedCount;
    double scrollAcc;
    int bag[7], bagIndex;
}
@property (strong, readwrite) NSWindow *window;
@property (strong) RGStackView *view;
@property (strong) NSTimer *timer;
@property (strong) NSView *overlay;
@property (strong) NSTextField *overlayLabel;
- (void)steerTo:(CGFloat)x;
- (void)rotate:(int)dir;
- (void)softDrop;
- (void)hardDrop;
- (void)move:(int)dx;
- (void)newGame;
- (void)togglePause;
- (long)droppedThisGame;
@end

@interface RGStackView : NSView
@property (weak) RGCheeseStack *game;
@end

@implementation RGCheeseStack

- (instancetype)init {
    if ((self = [super init])) best = [NSUserDefaults.standardUserDefaults integerForKey:kBestKey];
    return self;
}

- (void)show {
    if (!self.window) {
        self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, WIN_W, WIN_H)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
            backing:NSBackingStoreBuffered defer:NO];
        self.window.title = @"Cheese Stack — a RodentGym workout";
        self.window.tabbingMode = NSWindowTabbingModeDisallowed;
        self.window.releasedWhenClosed = NO;
        self.window.acceptsMouseMovedEvents = YES;
        self.window.delegate = self;
        self.view = [[RGStackView alloc] initWithFrame:NSMakeRect(0, 0, WIN_W, WIN_H)];
        self.view.game = self;
        self.window.contentView = self.view;
        [self buildOverlay];
        [self.window center];
        [self.window setFrameAutosaveName:@"RodentGymCheeseStack"];
    }
    if (!started) [self newGame];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.view];
    if (!self.timer) {
        self.timer = [NSTimer timerWithTimeInterval:1.0 / 60 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
    lastTick = CFAbsoluteTimeGetCurrent();
}

// Paused and game-over messages float over the board on Liquid Glass.
- (void)buildOverlay {
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 220, 150)];
    self.overlayLabel = [NSTextField wrappingLabelWithString:@""];
    self.overlayLabel.alignment = NSTextAlignmentCenter;
    self.overlayLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    self.overlayLabel.textColor = NSColor.labelColor;
    self.overlayLabel.frame = NSMakeRect(14, 14, 192, 122);
    self.overlayLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:self.overlayLabel];
    self.overlay = RGGlassView(content, 26);
    self.overlay.frame = NSMakeRect(PAD + (BOARD_W - 220) / 2, PAD + (BOARD_H - 150) / 2, 220, 150);
    self.overlay.hidden = YES;
    self.overlay.accessibilityElement = YES;
    self.overlay.accessibilityRole = NSAccessibilityStaticTextRole;
    [self.view addSubview:self.overlay];
}

- (void)updateOverlay {
    NSString *message = over ? [NSString stringWithFormat:@"Game over\n%ld points\n\nClick or press Space\nto play again", score]
                      : paused ? @"Paused\n\nClick to resume" : nil;
    if (!message || frozen) { self.overlay.hidden = YES; return; }
    if (![self.overlayLabel.stringValue isEqualToString:message]) {
        self.overlayLabel.stringValue = message;
        self.overlay.accessibilityLabel = [message stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        // Centre the text vertically inside the glass
        NSSize fit = [self.overlayLabel sizeThatFits:NSMakeSize(192, 122)];
        self.overlayLabel.frame = NSMakeRect(14, (150 - fit.height) / 2, 192, fit.height);
    }
    self.overlay.hidden = NO;
}

- (void)showDemo {
    [self show];
    for (int y = ROWS - 7; y < ROWS; y++)
        for (int x = 0; x < COLS; x++)
            if ((x * 7 + y * 3) % 11 != 0 && !(y < ROWS - 4 && x > 5)) board[y][x] = 1 + (x + y * 2) % 7;
    type = 2; memcpy(cells, kShapes[2], sizeof cells); px = 6; py = 8;
    nextType = 0;
    score = 4820; lines = 23; level = 3; best = MAX(best, 6150);
    leftClicks = 41; rightClicks = 37; scrollDrops = 52; slams = 9;
    frozen = YES;
    flashRight = CFAbsoluteTimeGetCurrent() + 3600;
    self.view.needsDisplay = YES;
}

- (void)windowWillClose:(NSNotification *)n {
    [self.timer invalidate];
    self.timer = nil;
    if (started && !over) paused = YES;
}

- (void)windowDidResignKey:(NSNotification *)n {
    if (started && !over) paused = YES;
    self.view.needsDisplay = YES;
}

- (long)droppedThisGame { return self.droppedClicks ? MAX(0, self.droppedClicks() - dropsAtStart) : 0; }

- (int)drawFromBag {
    if (bagIndex == 0) {
        for (int i = 0; i < 7; i++) bag[i] = i;
        for (int i = 6; i > 0; i--) { int j = (int)arc4random_uniform((uint32_t)i + 1), t = bag[i]; bag[i] = bag[j]; bag[j] = t; }
    }
    int t = bag[bagIndex];
    bagIndex = (bagIndex + 1) % 7;
    return t;
}

- (void)newGame {
    memset(board, 0, sizeof board);
    score = lines = leftClicks = rightClicks = scrollDrops = slams = 0;
    level = 1;
    over = paused = NO;
    started = YES;
    gravityAcc = scrollAcc = 0;
    clearedCount = 0;
    bagIndex = 0;
    dropsAtStart = self.droppedClicks ? self.droppedClicks() : 0;
    nextType = [self drawFromBag];
    [self spawn];
    self.view.needsDisplay = YES;
}

- (BOOL)collides:(const RGPt *)c x:(int)x y:(int)y {
    for (int i = 0; i < 4; i++) {
        int cx = x + c[i].x, cy = y + c[i].y;
        if (cx < 0 || cx >= COLS || cy >= ROWS) return YES;
        if (cy >= 0 && board[cy][cx]) return YES;
    }
    return NO;
}

- (void)spawn {
    type = nextType;
    nextType = [self drawFromBag];
    memcpy(cells, kShapes[type], sizeof cells);
    px = 3;
    py = type == 0 ? -1 : 0;
    if ([self collides:cells x:px y:py]) [self gameOver];
}

- (void)gameOver {
    over = YES;
    if (score > best) {
        best = score;
        [NSUserDefaults.standardUserDefaults setInteger:best forKey:kBestKey];
    }
}

- (BOOL)tryMoveX:(int)dx y:(int)dy {
    if ([self collides:cells x:px + dx y:py + dy]) return NO;
    px += dx;
    py += dy;
    return YES;
}

- (void)move:(int)dx {
    if (over || paused) return;
    [self tryMoveX:dx y:0];
    self.view.needsDisplay = YES;
}

// dir +1 = clockwise, -1 = anticlockwise. Simple wall kicks keep rotation forgiving near edges.
- (void)rotate:(int)dir {
    if (over || paused || type == 1) return;
    int n = type == 0 ? 4 : 3;
    RGPt r[4];
    for (int i = 0; i < 4; i++)
        r[i] = dir > 0 ? (RGPt){n - 1 - cells[i].y, cells[i].x} : (RGPt){cells[i].y, n - 1 - cells[i].x};
    static const RGPt kicks[] = {{0, 0}, {-1, 0}, {1, 0}, {-2, 0}, {2, 0}, {0, -1}};
    for (size_t k = 0; k < sizeof kicks / sizeof kicks[0]; k++) {
        if (![self collides:r x:px + kicks[k].x y:py + kicks[k].y]) {
            memcpy(cells, r, sizeof cells);
            px += kicks[k].x;
            py += kicks[k].y;
            break;
        }
    }
    self.view.needsDisplay = YES;
}

- (void)lock {
    for (int i = 0; i < 4; i++) {
        int cy = py + cells[i].y, cx = px + cells[i].x;
        if (cy < 0) { [self gameOver]; return; }
        board[cy][cx] = type + 1;
    }
    // Find full rows top to bottom, then remove them in that order (removing a row only shifts rows above it)
    clearedCount = 0;
    for (int y = 0; y < ROWS && clearedCount < 4; y++) {
        BOOL full = YES;
        for (int x = 0; x < COLS; x++) if (!board[y][x]) { full = NO; break; }
        if (full) clearedRows[clearedCount++] = y;
    }
    for (int i = 0; i < clearedCount; i++) {
        int y = clearedRows[i];
        memmove(board[1], board[0], sizeof(int) * COLS * (size_t)y);
        memset(board[0], 0, sizeof(int) * COLS);
    }
    if (clearedCount) {
        lines += clearedCount;
        score += kLineScores[MIN(clearedCount, 4)] * level;
        level = lines / 10 + 1;
        clearFlashUntil = CFAbsoluteTimeGetCurrent() + 0.25;
    }
    [self spawn];
}

- (void)softDrop {
    if (over || paused) return;
    if ([self tryMoveX:0 y:1]) score += 1;
    else [self lock];
    gravityAcc = 0;
    self.view.needsDisplay = YES;
}

- (void)hardDrop {
    if (over || paused) return;
    while ([self tryMoveX:0 y:1]) score += 2;
    [self lock];
    gravityAcc = 0;
    flashSlam = CFAbsoluteTimeGetCurrent();
    self.view.needsDisplay = YES;
}

- (int)ghostY {
    int y = py;
    while (![self collides:cells x:px y:y + 1]) y++;
    return y;
}

// Moves the piece one column at a time towards the pointer, stopping at walls and stacks.
- (void)steerTo:(CGFloat)x {
    if (over || paused) return;
    int minX = 9, maxX = 0;
    for (int i = 0; i < 4; i++) { minX = MIN(minX, cells[i].x); maxX = MAX(maxX, cells[i].x); }
    int column = (int)floor((x - PAD) / CELL);
    int target = column - (minX + maxX + 1) / 2;
    while (px < target && [self tryMoveX:1 y:0]) {}
    while (px > target && [self tryMoveX:-1 y:0]) {}
    self.view.needsDisplay = YES;
}

- (void)togglePause {
    if (over) return;
    paused = !paused;
    lastTick = CFAbsoluteTimeGetCurrent();
    self.view.needsDisplay = YES;
}

- (void)tick {
    double now = CFAbsoluteTimeGetCurrent(), dt = MIN(0.1, now - lastTick);
    lastTick = now;
    if (started && !over && !paused && !frozen) {
        double interval = MAX(0.06, 0.8 * pow(0.85, level - 1));
        gravityAcc += dt;
        while (gravityAcc >= interval && !over) {
            gravityAcc -= interval;
            if (![self tryMoveX:0 y:1]) [self lock];
        }
    }
    [self updateOverlay];
    self.view.needsDisplay = YES;
}

#pragma mark Demo snapshot

- (BOOL)writeDemoSnapshotTo:(NSString *)path {
    [self newGame];
    for (int y = ROWS - 7; y < ROWS; y++)
        for (int x = 0; x < COLS; x++)
            if ((x * 7 + y * 3) % 11 != 0 && !(y < ROWS - 4 && x > 5)) board[y][x] = 1 + (x + y * 2) % 7;
    type = 2; memcpy(cells, kShapes[2], sizeof cells); px = 6; py = 8;
    nextType = 0;
    score = 4820; lines = 23; level = 3; best = MAX(best, 6150);
    leftClicks = 41; rightClicks = 37; scrollDrops = 52; slams = 9;
    flashRight = CFAbsoluteTimeGetCurrent();
    RGStackView *v = [[RGStackView alloc] initWithFrame:NSMakeRect(0, 0, WIN_W, WIN_H)];
    v.game = self;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
@end

#pragma mark - View

@implementation RGStackView {
    NSTrackingArea *tracking;
    BOOL slamLatched;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (NSMenu *)menuForEvent:(NSEvent *)event { return nil; }   // right click is a game input, not a context menu

- (void)updateTrackingAreas {
    if (tracking) [self removeTrackingArea:tracking];
    tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:tracking];
    [super updateTrackingAreas];
}

- (NSPoint)local:(NSEvent *)e { return [self convertPoint:e.locationInWindow fromView:nil]; }

- (void)mouseMoved:(NSEvent *)e { [self.game steerTo:[self local:e].x]; }
- (void)mouseDragged:(NSEvent *)e { [self.game steerTo:[self local:e].x]; }

- (BOOL)resumeOrRestart {
    RGCheeseStack *g = self.game;
    if (g->over) { [g newGame]; return YES; }
    if (g->paused) { [g togglePause]; return YES; }
    return NO;
}

- (void)mouseDown:(NSEvent *)e {
    if ([self resumeOrRestart]) return;
    if (e.modifierFlags & NSEventModifierFlagControl) { [self rightMouseDown:e]; return; }   // Control-click counts as right
    RGCheeseStack *g = self.game;
    g->leftClicks++;
    g->flashLeft = CFAbsoluteTimeGetCurrent();
    [g rotate:-1];
}

- (void)rightMouseDown:(NSEvent *)e {
    if ([self resumeOrRestart]) return;
    RGCheeseStack *g = self.game;
    g->rightClicks++;
    g->flashRight = CFAbsoluteTimeGetCurrent();
    [g rotate:+1];
}

- (void)otherMouseDown:(NSEvent *)e {
    RGCheeseStack *g = self.game;
    if (g->over || g->paused) return;
    g->slams++;
    [g hardDrop];
}

// Scrolling either way soft-drops; one fast flick slams the piece down. Momentum is ignored so a
// flick doesn't keep dropping the next piece.
- (void)scrollWheel:(NSEvent *)e {
    RGCheeseStack *g = self.game;
    if (g->over || g->paused) return;
    if (e.phase == NSEventPhaseBegan || e.phase == NSEventPhaseMayBegin) slamLatched = NO;
    if (e.momentumPhase != NSEventPhaseNone) return;
    CGFloat dy = fabs(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 1 : 12);
    double now = CFAbsoluteTimeGetCurrent();
    if (e.hasPreciseScrollingDeltas && dy >= 42 && !slamLatched && now - g->lastSlam > 0.35) {
        slamLatched = YES;
        g->lastSlam = now;
        g->slams++;
        g->scrollAcc = 0;
        [g hardDrop];
        return;
    }
    if (slamLatched) return;
    g->scrollAcc += dy;
    while (g->scrollAcc >= 14) {
        g->scrollAcc -= 14;
        g->scrollDrops++;
        [g softDrop];
    }
}

- (void)keyDown:(NSEvent *)e {
    RGCheeseStack *g = self.game;
    NSString *k = e.charactersIgnoringModifiers.lowercaseString;
    unichar c = k.length ? [k characterAtIndex:0] : 0;
    if (g->over && (c == ' ' || c == '\r')) { [g newGame]; return; }
    switch (c) {
        case NSLeftArrowFunctionKey:  [g move:-1]; break;
        case NSRightArrowFunctionKey: [g move:+1]; break;
        case NSUpArrowFunctionKey: case 'x': [g rotate:+1]; break;
        case 'z': [g rotate:-1]; break;
        case NSDownArrowFunctionKey: [g softDrop]; break;
        case ' ': [g hardDrop]; break;
        case 'p': case 27: [g togglePause]; break;
        default: [super keyDown:e];
    }
}

- (void)drawRect:(NSRect)dirty {
    RGCheeseStack *g = self.game;
    if (!g) return;
    double now = CFAbsoluteTimeGetCurrent();
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(self.bounds);

    // Board
    NSRect boardRect = NSMakeRect(PAD, PAD, BOARD_W, BOARD_H);
    RGDrawCard(NSInsetRect(boardRect, -6, -6), 14);
    [[NSColor.separatorColor colorWithAlphaComponent:0.18] setStroke];
    NSBezierPath *grid = [NSBezierPath bezierPath];
    grid.lineWidth = 0.5;
    for (int x = 1; x < COLS; x++) { [grid moveToPoint:NSMakePoint(PAD + x * CELL, PAD)]; [grid lineToPoint:NSMakePoint(PAD + x * CELL, PAD + BOARD_H)]; }
    for (int y = 1; y < ROWS; y++) { [grid moveToPoint:NSMakePoint(PAD, PAD + y * CELL)]; [grid lineToPoint:NSMakePoint(PAD + BOARD_W, PAD + y * CELL)]; }
    [grid stroke];

    for (int y = 0; y < ROWS; y++)
        for (int x = 0; x < COLS; x++)
            if (g->board[y][x]) drawCheese(NSMakeRect(PAD + x * CELL, PAD + y * CELL, CELL, CELL), g->board[y][x] - 1, (unsigned)(y * COLS + x + 1), 1);

    if (g->started && !g->over) {
        int gy = [g ghostY];
        for (int i = 0; i < 4; i++) {
            NSRect r = NSInsetRect(NSMakeRect(PAD + (g->px + g->cells[i].x) * CELL, PAD + (gy + g->cells[i].y) * CELL, CELL, CELL), 2, 2);
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:4 yRadius:4];
            [cheese(g->type, 0.10) setFill];
            [p fill];
            [cheese(g->type, 0.45) setStroke];
            p.lineWidth = 1.2;
            [p stroke];
        }
        for (int i = 0; i < 4; i++) {
            int cy = g->py + g->cells[i].y;
            if (cy < 0) continue;
            drawCheese(NSMakeRect(PAD + (g->px + g->cells[i].x) * CELL, PAD + cy * CELL, CELL, CELL), g->type, (unsigned)(i + g->type * 4 + 101), 1);
        }
    }

    if (now < g->clearFlashUntil) {
        CGFloat a = (g->clearFlashUntil - now) / 0.25;
        [[NSColor colorWithWhite:1 alpha:0.5 * a] setFill];
        for (int i = 0; i < MIN(g->clearedCount, 4); i++)
            NSRectFillUsingOperation(NSMakeRect(PAD, PAD + g->clearedRows[i] * CELL, BOARD_W, CELL), NSCompositingOperationSourceOver);
    }

    [self drawPanel:now];
}

- (void)drawPanel:(double)now {
    RGCheeseStack *g = self.game;
    CGFloat x = PANEL_X, y = PAD - 4, w = PANEL_W;
    NSFont *small = [NSFont systemFontOfSize:11], *head = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    NSFont *num = [NSFont monospacedDigitSystemFontOfSize:20 weight:NSFontWeightSemibold];
    NSFont *mono = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];

    label(@"Cheese Stack", x, y, [NSFont systemFontOfSize:20 weight:NSFontWeightBold], NSColor.systemOrangeColor);
    label(@"a RodentGym workout", x, y + 26, small, NSColor.secondaryLabelColor);

    // Next piece
    y += 52;
    label([@"NEXT · " stringByAppendingString:[kCheeseNames[g->nextType] uppercaseString]], x, y, head, NSColor.secondaryLabelColor);
    NSRect box = NSMakeRect(x, y + 18, w, 62);
    RGDrawCard(box, 12);
    CGFloat mc = 18;
    int minX = 9, maxX = 0, minY = 9, maxY = 0;
    for (int i = 0; i < 4; i++) {
        minX = MIN(minX, kShapes[g->nextType][i].x); maxX = MAX(maxX, kShapes[g->nextType][i].x);
        minY = MIN(minY, kShapes[g->nextType][i].y); maxY = MAX(maxY, kShapes[g->nextType][i].y);
    }
    CGFloat ox = NSMidX(box) - (maxX - minX + 1) * mc / 2, oy = NSMidY(box) - (maxY - minY + 1) * mc / 2;
    for (int i = 0; i < 4; i++)
        drawCheese(NSMakeRect(ox + (kShapes[g->nextType][i].x - minX) * mc, oy + (kShapes[g->nextType][i].y - minY) * mc, mc, mc), g->nextType, (unsigned)(i + 7), 1);

    // Score
    y += 92;
    NSArray *stats = @[@[@"SCORE", @(g->score)], @[@"LINES", @(g->lines)], @[@"LEVEL", @(g->level)], @[@"BEST", @(MAX(g->best, g->score))]];
    for (NSUInteger i = 0; i < stats.count; i++) {
        CGFloat sx = x + (i % 2) * (w / 2), sy = y + (i / 2) * 46;
        label(stats[i][0], sx, sy, head, NSColor.secondaryLabelColor);
        label([stats[i][1] stringValue], sx, sy + 14, num, NSColor.labelColor);
    }

    // Inputs: each button lights briefly when it arrives, so a missing click is obvious
    y += 104;
    label(@"INPUTS THIS GAME", x, y, head, NSColor.secondaryLabelColor);
    y += 18;
    NSArray *pads = @[@[@"↺  Left", @(g->leftClicks), @(g->flashLeft)], @[@"↻  Right", @(g->rightClicks), @(g->flashRight)]];
    for (NSUInteger i = 0; i < 2; i++) {
        NSRect r = NSMakeRect(x + i * (w / 2 + 3), y, w / 2 - 3, 46);
        BOOL lit = now - [pads[i][2] doubleValue] < 0.18;
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:12 yRadius:12];
        [(lit ? NSColor.systemGreenColor : NSColor.tertiarySystemFillColor) setFill];
        [p fill];
        label(pads[i][0], r.origin.x + 10, r.origin.y + 6, head, lit ? NSColor.whiteColor : NSColor.secondaryLabelColor);
        label([pads[i][1] stringValue], r.origin.x + 10, r.origin.y + 21, num, lit ? NSColor.whiteColor : NSColor.labelColor);
    }
    y += 54;
    label([NSString stringWithFormat:@"Scroll drops %ld · slams %ld", g->scrollDrops, g->slams], x, y, mono,
          now - g->flashSlam < 0.18 ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor);
    long dropped = [g droppedThisGame];
    y += 20;
    label([NSString stringWithFormat:@"Dropped clicks %ld", dropped], x, y, mono,
          dropped ? NSColor.systemRedColor : NSColor.systemGreenColor);

    // Setup warning (e.g. right-click switched off) and controls
    NSString *warning = g.inputWarning ? g.inputWarning() : nil;
    y += 26;
    if (warning.length) {
        NSRect r = NSMakeRect(x, y, w, 58);
        [[NSString stringWithFormat:@"⚠︎ %@", warning] drawWithRect:r options:NSStringDrawingUsesLineFragmentOrigin
            attributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: NSColor.systemOrangeColor}];
        y += 62;
    }
    NSString *help = @"Steer with the pointer\nLeft click ↺ · right click ↻\nScroll to drop · flick to slam\nKeys: ← → ↑ Z X ↓ Space · P pause";
    [help drawWithRect:NSMakeRect(x, MAX(y, PAD + BOARD_H - 62), w, 64) options:NSStringDrawingUsesLineFragmentOrigin
        attributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
}
@end
