# WBWrite FAQ and troubleshooting

> Answers to common questions about WBWrite, the free, open-source stage whiteboard for macOS with NDI® and HDMI output.

## Is WBWrite free?

Yes. WBWrite is free and open source. It's made by 4H1M, z.s., a Czech nonprofit. If it helps your show, you can support 4H1M at https://www.darujme.cz/4h1m.

## Which platforms are supported?

macOS 13 or later, on Apple Silicon and Intel. Windows and Linux builds are coming soon.

## The NDI source doesn't appear on my receiver.

- Open **System Settings → Privacy & Security → Local Network** and make sure WBWrite is turned on.
- Check that the Mac and the receiver are on the same network and subnet.
- Check that multicast and mDNS (Bonjour) aren't blocked by the network switch or firewall.
- Look at the status line on the touchscreen. `NDI waiting` means WBWrite is sending and no receiver has connected yet.

## Can I key the writing over other graphics?

Yes. Set **Background** to *Transparent*. WBWrite then sends BGRA with straight alpha, so the receiver can key out everything except the writing.

## What does the performer see compared with the audience?

The board on the touchscreen has exactly the aspect ratio of the output. Everything inside the board is sent pixel for pixel. The hatched area, border, clear button and status line stay on the touchscreen only.

## Can I prevent someone from clearing the board by accident?

Set **Clear gesture** to *Double tap*, or to *None* to hide the button entirely. An operator can still clear the board with Backspace on a keyboard.

## Can I change the pen during the show?

No. Pen color and width are set in the setup window before the show, so nothing can change by accident in live mode.

## How do I report a bug or ask for a feature?

Open an issue at https://github.com/4H1Mzs/wbwriter/issues, or email simon@4h1m.com.

NDI® is a registered trademark of Vizrt NDI AB.
