# MirrorLab 0.3.1 — AirPlay media-engine foundation

0.3.1 starts the media-engine branch after 0.2.6 proved that a real iPad can complete FairPlay setup, open the type-110 mirror TCP stream, send an H.264 `avcC` configuration, and negotiate type-96 audio UDP.

## AirPlay

- FairPlay is moved behind a small replaceable `FairPlayProvider` / `FairPlaySession` interface. The current bootstrap provider preserves the 0.2.x FPLY 3.1 interoperability handshake; session-key unwrap is deliberately a separate backend boundary.
- Added a native `AirPlayVideoDecoder` using Apple VideoToolbox with **hardware decoding required**. It accepts `avcC`, builds a CoreMedia H.264 format description, decodes asynchronously to `CVPixelBuffer`, and pushes frames into the same `LatestVideoFrameStore` used by the proven USB Metal renderer.
- Both the embedded AirPlay preview and the separate preview window are now connected to the existing Metal render surface. As soon as a FairPlay backend produces decrypted H.264 access units, no second renderer/window architecture is required.
- Mirror packet framing now validates the documented option field (`0x0006` for video/codec, `0x001e` for heartbeat) in addition to packet type and payload size. This removes the false resync that made encrypted payload bytes look like multi-megabyte H.264 packets in 0.2.6.
- Repetitive empty `POST /feedback` heartbeats are answered normally but no longer spam the Events/protocol UI.
- Stopping AirPlay no longer destroys the last session's diagnostic counters before a report is exported.
- Diagnostics now include FairPlay backend/key status and decoded AirPlay frame count.

## USB

The working USB capture, audio, frame pacing, and Metal renderer were intentionally left unchanged.

## Still missing before first AirPlay picture

The current bootstrap FairPlay provider does not yet unwrap the 72-byte `ekey`. The next integration step is an embedded source-level FairPlay/PlayFair provider (not an external executable), followed by mirror AES decryption. VideoToolbox + Metal are already wired for the decrypted output.
