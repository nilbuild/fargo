# Fargo

A native macOS streaming studio. Stream to several platforms at once, record locally in 4K, and build your scene on the GPU.

![macOS](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

<!-- ![Fargo screenshot](screenshot.png) -->

## Features

- Stream to YouTube, Twitch, Kick, Facebook, X and custom RTMP at the same time
- Each destination gets its own resolution and bitrate, all from one render pass
- Record 4K HEVC on your Mac while you stream
- Scene compositing on the GPU, on one 4K Metal texture at 60fps
- Camera, screen capture, media files, images and GIFs as sources
- Blur or remove the background with on-device person segmentation
- Text, image, media, chat and caption overlays that you can place anywhere
- Live captions from on-device speech recognition
- YouTube and Twitch chat, in a panel or on the stream
- Soundboard with built-in and custom effects
- Mic and system audio mixing with noise gate, EQ and compressor
- Auto-reconnect per destination, with live bitrate and dropped-frame stats
- In-app updates with Sparkle

## Requirements

macOS 14.0 or later, Apple Silicon or Intel.

## Install

Download the latest `.dmg` from [Releases](https://github.com/nilbuild/fargo/releases). The builds are signed with a Developer ID and notarized, so they open normally under Gatekeeper.

## Build from source

You need Xcode 26 or later.

```bash
git clone https://github.com/nilbuild/fargo
cd fargo
make build   # build the app
make run     # build and launch
make test    # run the tests
```

### YouTube and Twitch chat

Live chat is the only feature that needs a sign-in. Streaming, recording, scenes,
overlays and captions all work without one, because a destination only needs the
RTMP URL and stream key you paste in.

The client IDs are built into the app, so you just sign in from the sidebar. They
are public identifiers, not secrets. Both flows are public clients, so Fargo never
holds a client secret.

If you fork Fargo and want chat to point at your own Google and Twitch projects,
replace `TwitchAuth.clientId` and `YouTubeAuth.clientId`. Register the Google client
as type **iOS** with bundle id `com.fargo.app`, and put the reversed client id into
`CFBundleURLSchemes` in `Info.plist`. Register the Twitch app with client type
**Public**. Picking Google's "Desktop app" type or Twitch's "Confidential" type forces
a client secret, which breaks token refresh.

## Architecture

Everything is composited onto one 3840x2160 Metal texture at 60fps. That texture then feeds two paths:

- **Recording**: the 4K texture goes to `AVAssetWriter` as HEVC
- **Streaming**: the texture is scaled down to 1080p, encoded as H.264 by VideoToolbox, and sent over RTMP

`StreamManager` gives the 4K buffer to destinations that accept more than 1080p, and the 1080p buffer to the rest. Both buffers are made every frame.

RTMP is written from scratch in `Services/RTMP` (handshake, chunking, AMF0). FLV muxing is in `Services/Encoding`. There is no FFmpeg and no browser runtime.

### Platform limits

Each preset uses the highest settings that the platform accepts.

| Platform | Resolution | Video | Audio | FPS |
|----------|-----------|-------|-------|-----|
| YouTube  | 3840x2160 | 20 Mbps  | 320 kbps | 60 |
| Twitch   | 1920x1080 | 8.5 Mbps | 320 kbps | 60 |
| Kick     | 1920x1080 | 8 Mbps   | 320 kbps | 60 |
| Facebook | 1920x1080 | 8 Mbps   | 320 kbps | 30 |
| X        | 1920x1080 | 9 Mbps   | 128 kbps | 30 |
| Custom   | 1920x1080 | 6 Mbps   | 160 kbps | 30 |

X and Custom have no preset RTMP URL, so you add your own. You can edit every value for each destination.

## License

MIT, see [LICENSE](LICENSE).
