// Help — a native help window: topics in a sidebar, searchable, rendered from Resources/Help.md.
//
// Help.md uses a deliberately small format (see the comment at the top of that file), parsed here
// into native text so the help follows the system fonts, accent colour, and light and dark mode.
//
// MIT License — see LICENSE.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RGHelp : NSObject <NSWindowDelegate, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>

@property (strong, readonly, nullable) NSWindow *window;

- (void)show;

/// Shows the help with the topic whose title starts with `title` selected.
- (void)showTopic:(NSString *)title;

@end

NS_ASSUME_NONNULL_END
