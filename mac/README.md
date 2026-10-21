# 7XEN Studio for macOS

Native SwiftUI rewrite of the 7XEN Studio console: phones stream in over the LAN (MediaMTX / HLS), a Metal compositor
mixes scenes at 1080p60, and a VideoToolbox pipeline records and streams to YouTube / Facebook / custom RTMP.

Requires macOS 14+, Swift 6.x command line tools (no Xcode needed).

## Build & run

    swift build            # debug
    swift run Studio       # run unbundled (no camera/mic permission prompts)
    scripts/bundle.sh      # release build -> dist/7XEN Studio.app (ad-hoc signed)
    open "dist/7XEN Studio.app"

`bundle.sh` copies `mediamtx` and `ffmpeg` from `/opt/homebrew/bin` into `Contents/Resources` when present
(`brew install mediamtx ffmpeg`).

## Layout

- `Sources/Studio/Core` – store, device HTTP API, interfaces shared between modules
- `Sources/Studio/Ingest` – HTTP server, MediaMTX supervisor, phone frame sources
- `Sources/Studio/Engine` – Metal compositor (`StudioEngine`)
- `Sources/Studio/Output` – VideoToolbox/ffmpeg output pipeline
- `Sources/Studio/UI` – SwiftUI app. The UI only talks to `StudioServices` (`UI/Services.swift`);
  `MockServices` runs standalone, `RealServices` wires the real modules.

## Using it

- **Add a phone**: Add in the Phones panel, name it, scan the QR with the 7XEN Stream app (or type the pairing code).
- **Scenes**: `1`-`9` select a scene into Preview, `Space` (or TAKE) sends Preview to Program, double-click a scene to cut to it.
- **Go Live**: pick outputs (record / stream keys), press Go Live and confirm. The health strip shows fps, bitrate, dropped frames.
- Menu `Show` has all commands; `Settings` (Cmd+,) holds the studio name and stream keys.
