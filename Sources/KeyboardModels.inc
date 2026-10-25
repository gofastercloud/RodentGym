// Apple keyboards by product ID — included by Keyboard.m.
//
// Magic Keyboards use one product ID for every layout and report vendor 0x05AC over USB and 0x004C
// over Bluetooth; the layout comes from the HID country code (13 ISO, 15 JIS, 33 US). The aluminium
// Apple Wireless Keyboards have a product ID per layout, so their family is fixed here.
// Sources: Linux hid-ids.h and hid-apple.c, systemd's keyboard hwdb, usb.ids and Apple's spec pages.
//
//  productID family  name                                                         years     layout             topKey      globe
    {0x022c, 0,  @"Apple Wireless Keyboard",                                      @"2007",  @"classic_%@",     @"eject",   NO},
    {0x022d, 1,  @"Apple Wireless Keyboard",                                      @"2007",  @"classic_%@",     @"eject",   NO},
    {0x022e, 2,  @"Apple Wireless Keyboard",                                      @"2007",  @"classic_%@",     @"eject",   NO},
    {0x0239, 0,  @"Apple Wireless Keyboard",                                      @"2009",  @"classic_%@",     @"eject",   NO},
    {0x023a, 1,  @"Apple Wireless Keyboard",                                      @"2009",  @"classic_%@",     @"eject",   NO},
    {0x023b, 2,  @"Apple Wireless Keyboard",                                      @"2009",  @"classic_%@",     @"eject",   NO},
    {0x0255, 0,  @"Apple Wireless Keyboard",                                      @"2011",  @"classic_%@",     @"eject",   NO},
    {0x0256, 1,  @"Apple Wireless Keyboard",                                      @"2011",  @"classic_%@",     @"eject",   NO},
    {0x0257, 2,  @"Apple Wireless Keyboard",                                      @"2011",  @"classic_%@",     @"eject",   NO},
    {0x0267, -1, @"Magic Keyboard",                                               @"2015",  @"compact_%@_2015", @"eject",  NO},
    {0x026c, -1, @"Magic Keyboard with Numeric Keypad",                           @"2017",  @"full_%@_2017",   @"eject",   NO},
    {0x029c, -1, @"Magic Keyboard",                                               @"2021",  @"compact_%@_2021", @"lock",   YES},
    {0x029a, -1, @"Magic Keyboard with Touch ID",                                 @"2021",  @"compact_%@_2021", @"touchid", YES},
    {0x029f, -1, @"Magic Keyboard with Touch ID and Numeric Keypad",              @"2021",  @"full_%@_2021",   @"touchid", YES},
    {0x0320, -1, @"Magic Keyboard (USB‑C)",                                       @"2024",  @"compact_%@_2021", @"lock",   YES},
    {0x0321, -1, @"Magic Keyboard with Touch ID (USB‑C)",                         @"2024",  @"compact_%@_2021", @"touchid", YES},
    {0x0322, -1, @"Magic Keyboard with Touch ID and Numeric Keypad (USB‑C)",      @"2024",  @"full_%@_2024",   @"touchid", YES},
