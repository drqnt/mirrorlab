# MirrorLab 0.3.29 — third-party notices

MirrorLab 0.3.29 is distributed under the **GNU General Public License version 3**. See the root `LICENSE` file.

## PlayFair

MirrorLab vendors the PlayFair FairPlay interoperability implementation originally by **EstebanKubata**. The source is in `Vendor/PlayFair/` and is licensed under GNU GPL v3.

The exact source lineage used for this prototype is recorded in `Vendor/PlayFair/PROVENANCE.md`. MirrorLab compiles those C sources into `libMirrorFairPlay.dylib` during the local build.

Important architectural distinction: `libMirrorFairPlay.dylib` is a small source-built library loaded inside the MirrorLab process. MirrorLab does **not** embed or launch UxPlay, RPiPlay, GStreamer, or another complete AirPlay receiver/player. MirrorLab owns Bonjour, RTSP/HTTP, media transports, packet parsing, diagnostics, windows, VideoToolbox decode, Metal rendering, and the native low-latency CoreAudio path.

## FairPlay interoperability records

The provider bridge includes the four legacy 142-byte FPLY 3.1 receiver response records for modes 0–3. These are Apple-protocol interoperability data that have been documented by multiple independent AirPlay receiver implementations; they are not claimed as original MirrorLab cryptography.

MirrorLab's use here is for ordinary user-initiated device screen mirroring. This project does not implement FairPlay Streaming content-DRM extraction.

## Apple system frameworks

MirrorLab uses Apple-provided system frameworks including Network.framework, AVFoundation, CoreMediaIO, CoreMedia/CoreVideo, VideoToolbox, Metal/MetalKit, CoreImage, CryptoKit/Security and AppKit/SwiftUI. They are supplied by macOS and are not redistributed third-party libraries in this repository.
