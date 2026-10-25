# SwiftHDR

A simple macOS app for turning SDR videos into HDR copies.

## What is this?

SwiftHDR converts your videos to HDR using FFmpeg and your Mac's hardware encoder. Drop in your files, choose a look, and save the results.

Everything runs on your Mac. Your videos aren't uploaded, and the originals stay untouched.

## How do I run it?

You'll need macOS 13 or newer, a Swift 6 toolchain, and a Mac that supports hardware encoding of 10-bit HEVC video.

First, install FFmpeg through Homebrew:

```sh
brew install ffmpeg-full
```

Download this repository, extract it, and open a terminal in the project folder. Then run:

```sh
bash scripts/build-app.sh
open build/SwiftHDR.app
```

This builds the app and signs it locally. FFmpeg is installed separately and must stay on your Mac.

## How do I use it?

1. Drop MP4, MOV, or M4V videos into the app, or click **Choose Videos**.
2. Pick a look: **Natural**, **Dynamic**, or **Pro**.
3. Choose where to save the converted videos. By default, they're saved beside the originals.
4. Click **Convert to HDR**.

Outputs are named `video_HDR_HLG.mp4`. If that name is already taken, SwiftHDR adds a number instead of overwriting it. You can stop a conversion with **Stop**.

## Which look should I choose?

- **Natural:** A subtle boost in color.
- **Dynamic:** A brighter, richer look. This is the default.
- **Pro:** Stronger color and contrast.

Try Dynamic first, then switch to Natural or Pro if you want a softer or stronger result.

## What kind of video does it create?

SwiftHDR saves 10-bit HEVC video in an MP4 file, using HLG HDR and BT.2020 color. It keeps the source frame rate and dimensions, padding by one pixel when a dimension is odd. Audio is converted to AAC when present.

It works with the detail already in your video. It can't recover blown-out highlights or detail that wasn't recorded, and it skips videos that are already HDR.

## Something isn't working

**FFmpeg isn't found:** Install `ffmpeg-full`, then click **Check Again**.

**Hardware encoding isn't available:** Your Mac needs support for 10-bit HEVC encoding. Close other video exports and try **Check Again**.

**The result looks washed out:** Try an HDR-capable display and a player that supports HDR. HLG video can look different on an SDR screen.

## Building and testing

To run the app directly from the source:

```sh
swift run SwiftHDR
```

To run the tests:

```sh
swift test
```

The hardware conversion tests are optional and need a compatible Mac with FFmpeg installed:

```sh
SWIFTHDR_RUN_INTEGRATION=1 swift test
```
