# PlayFair provenance

This directory contains the PlayFair FairPlay interoperability implementation by EstebanKubata, as vendored by UxPlay.

Source snapshot used by MirrorLab:
- Upstream lineage: https://github.com/FDH2/UxPlay
- Snapshot commit: `9e402cc8025e64120339e7f3138b6b876ffca52f`
- Original location: `lib/playfair/`
- License: GNU GPL version 3 (see `LICENSE.md`)

MirrorLab does **not** embed the UxPlay application, GStreamer renderer, or UxPlay control/media stack. Only the source-level PlayFair crypto component is used behind MirrorLab's own provider API.
