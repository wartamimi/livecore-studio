# CDeckLink

LiveCore Studio's Blackmagic DeckLink / UltraStudio / Intensity capture input. `LCDeckLink.cpp`
talks to the DeckLink API through `DeckLinkAPIDispatch.cpp`, which loads
`/Library/Frameworks/DeckLinkAPI.framework` at run time (installed by Blackmagic Desktop Video).
LiveCore neither links nor ships that framework or the driver.

`decklink/` holds the DeckLink SDK 12.0 interface headers and `DeckLinkAPIDispatch.cpp`,
unchanged (as also used by OBS Studio and FFmpeg). They carry Blackmagic Design's permissive
licence notice in each file ("Permission is hereby granted, free of charge, … to use, reproduce,
display, distribute, execute, and transmit the Software, and to prepare derivative works …"),
which requires that notice to stay in every copy. API 12.0 interfaces are served by Desktop
Video 12 and later drivers.

Blackmagic Design, DeckLink, UltraStudio and Intensity are trademarks of Blackmagic Design Pty. Ltd.
