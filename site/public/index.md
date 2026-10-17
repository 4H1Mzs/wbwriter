# WBWriter

> Free, open-source live stage whiteboard for macOS. Performers write on a touchscreen, and the audience sees the writing on the LED wall over NDI® or HDMI, with no UI on stage. Made by 4H1M Production (4H1M, z.s.).

- Website: https://wbwriter.app/
- Download (macOS 13+, Apple Silicon and Intel, signed and notarized): https://github.com/4H1Mzs/wbwriter/releases/latest
- Source code: https://github.com/4H1Mzs/wbwriter
- Current version: 1.1.0
- Price: free
- License: MIT (open source)
- Support: simon@4h1m.com
- Made by: [4H1M, z.s.](https://4h1m.com/), a Czech nonprofit audiovisual production

## What it does

WBWriter is a stripped-down, show-safe stage whiteboard inspired by OpenBoard. Everything is set before the show. In live mode the performer gets only a board and an eraser, and the video desk gets a clean signal.

## Features

- **Clean NDI® feed.** Only the inside of the board is sent, with no UI and no border. The NDI source name and frame rate (23.976 to 60 fps) are configurable. Uses NDI 6.3.
- **Black or transparent background.** Black is sent as BGRX. Transparent is sent as BGRA with straight alpha, for keying the writing over graphics.
- **Exact LED wall resolution.** Enter the wall's pixel size (1920×1080, 3840×2160 or custom). The board is scaled to fit the touchscreen with the aspect ratio locked, so what the performer sees is what goes out.
- **HDMI program out.** An optional full-screen clean feed on any external display, alongside NDI or instead of it.
- **Hatched no-draw zone.** The area around the board is hatched, so it's clear where you can't draw. The board stays clear of the MacBook camera notch.
- **Configurable clear button.** A large eraser in the corner you choose. Single tap, double tap (safer), or no button at all.
- **Operator status line.** A small readout beside the board shows NDI health, measured fps, receiver count, network TX, source name, resolution, and battery when running on battery. It never reaches the output.
- **Show-safe live mode.** Dock and menu bar are hidden and sleep is turned off. Esc goes back to setup.
- **One pen.** White by default, at the thickness of OpenBoard's strongest default pen. Color and width are set before the show.

## Signal chain

Touchscreen (MacBook with a touch display) → WBWriter (renders at the wall's resolution) → NDI® or HDMI → video desk (vMix, OBS, Resolume, TriCaster and others) → LED wall.

## How it works

1. **Set up before the show.** Choose resolution, frame rate, NDI name, background, pen color and width, the clear button's corner and gesture, and which screen is the touchscreen.
2. **Go live.** The board takes over the touchscreen. Receivers see the NDI source as `MACHINE (WBWriter)`.
3. **Write.** Smooth, round strokes at full output resolution.
4. **Clear and repeat.** Tap the eraser between messages. Press Esc when the show is over.

## Platforms

| Platform | Status |
|---|---|
| macOS 13 or later (Apple Silicon and Intel) | Available |
| Windows | Coming soon |
| Linux | Coming soon |

## Open source

WBWriter is open source under the MIT License. The code, issues, roadmap and releases are public on GitHub: https://github.com/4H1Mzs/wbwriter. It's written in Swift with AppKit. Every tagged version is built, signed and notarized automatically. Bug reports, ideas and pull requests are welcome.

Build from source:

```sh
git clone https://github.com/4H1Mzs/wbwriter
cd wbwriter
swift run
```

## About 4H1M

4H1M, z.s. (4H1M Production) is a Czech nonprofit audiovisual production serving churches and Christian events through sound, lighting, visuals, livestreaming and video. We build tools like WBWriter for our own shows and share them as free, open-source software.

- Support 4H1M: https://www.darujme.cz/4h1m
- Website: https://4h1m.com/
- Instagram: https://www.instagram.com/4h1m.production/
- Contact: simon@4h1m.com

## More documentation

- [Quick start](https://wbwriter.app/docs/quick-start.md)
- [FAQ and troubleshooting](https://wbwriter.app/docs/faq.md)

NDI® is a registered trademark of Vizrt NDI AB.
