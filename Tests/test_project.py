import os
import plistlib
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ProjectContractTests(unittest.TestCase):
    def test_info_plist_has_required_privacy_and_bonjour_entries(self):
        with (ROOT / "MirrorLab/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertTrue(info["NSCameraUsageDescription"])
        self.assertTrue(info["NSLocalNetworkUsageDescription"])
        self.assertEqual(set(info["NSBonjourServices"]), {"_airplay._tcp", "_raop._tcp"})
        self.assertEqual(info["CFBundleShortVersionString"], "0.3.50")
        self.assertEqual(info["CFBundleVersion"], "60")

    def test_every_swift_file_is_in_xcode_sources(self):
        project = (ROOT / "MirrorLab.xcodeproj/project.pbxproj").read_text()
        swift_files = sorted(path.name for path in (ROOT / "MirrorLab").rglob("*.swift"))
        for filename in swift_files:
            self.assertIn(f"{filename} in Sources", project, filename)

    def test_xcode_object_references_resolve(self):
        project = (ROOT / "MirrorLab.xcodeproj/project.pbxproj").read_text()
        defined = set(re.findall(r"^\s*([A-F0-9]{24})\b[^=\n]*=", project, re.MULTILINE))
        referenced = set(re.findall(r"\b([A-F0-9]{24})\b", project))
        self.assertEqual(referenced - defined, set())

    def test_native_airplay_control_plane_is_present(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        for token in (
            "NWListener",
            '"_airplay._tcp."',
            '"_raop._tcp."',
            'case ("GET", "/info")',
            'case ("POST", "/fp-setup")',
            "PropertyListSerialization.data",
            '"native-airplay-core"',
            "NetService.data(fromTXTRecord:",
        ):
            self.assertIn(token, source)
        self.assertNotIn("Process()", source)

    def test_no_uxplay_or_gstreamer_runtime_dependency_remains(self):
        self.assertFalse((ROOT / "Vendor/UxPlay").exists())
        self.assertFalse((ROOT / "Vendor/UxPlay.commit").exists())
        self.assertFalse((ROOT / "Scripts/build-uxplay.sh").exists())

        runtime_files = list((ROOT / "MirrorLab").rglob("*.swift")) + [
            ROOT / "Scripts/build-app.sh",
            ROOT / "Scripts/bootstrap.command",
            ROOT / "project.yml",
            ROOT / "MirrorLab.xcodeproj/project.pbxproj",
        ]
        banned = ("UxPlayController", "gst-launch", "gstreamer", "build-uxplay", "Vendor/UxPlay")
        for path in runtime_files:
            text = path.read_text()
            for token in banned:
                self.assertNotIn(token, text, f"{token} remains in {path}")

    def test_airplay_response_builders_are_explicitly_qualified(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertNotIn("send(response: .", source)
        for token in (
            "AirPlayResponse.ok(",
            "AirPlayResponse.badRequest(",
            "AirPlayResponse.notImplemented(",
        ):
            self.assertIn(token, source)

    def test_usb_discovers_quicktime_style_muxed_screen_devices(self):
        source = (ROOT / "MirrorLab/USB/USBCaptureController.swift").read_text()
        for token in (
            "kCMIOHardwarePropertyAllowScreenCaptureDevices",
            "AVCaptureDevice.DiscoverySession",
            "deviceTypes: [.external]",
            "mediaType: .muxed",
        ):
            self.assertIn(token, source)
        self.assertNotIn("AVCaptureDevice.devices(for: .video)", source)
        self.assertNotIn("selectedAudioDeviceID", source)
        self.assertNotIn("audioDevices", source)

    def test_usb_uses_same_muxed_input_for_video_and_audio(self):
        source = (ROOT / "MirrorLab/USB/USBCaptureController.swift").read_text()
        self.assertEqual(source.count("AVCaptureDeviceInput(device: device)"), 1)
        self.assertIn("session.addInput(input)", source)
        self.assertIn("session.addOutput(videoOutput)", source)
        self.assertIn("session.addOutput(audioOutput)", source)
        self.assertIn("videoOutput.videoSettings = [:]", source)

    def test_usb_uses_active_format_for_device_native_format(self):
        source = (ROOT / "MirrorLab/USB/USBCaptureController.swift").read_text()
        self.assertNotIn("session.canSetSessionPreset(.inputPriority)", source)
        self.assertNotIn("session.sessionPreset = .inputPriority", source)
        self.assertIn("device.activeFormat = selected.0", source)
        self.assertIn("kCMIOHardwarePropertyDevices", source)
        self.assertIn("kCMIODevicePropertyStreams", source)
        self.assertIn("kCMIOStreamPropertyFormatDescriptions", source)
        self.assertIn("kCMIOStreamPropertyFormatDescription", source)
        self.assertIn("CMIOObjectSetPropertyData", source)
        self.assertIn("CVPixelBufferGetWidth", source)
        self.assertIn('USB actual stream:', source)

    def test_scripts_are_executable(self):
        for script in (ROOT / "Scripts").iterdir():
            if script.suffix in {".sh", ".command"}:
                self.assertTrue(os.access(script, os.X_OK), script.name)

    def test_bootstrap_is_native_only(self):
        bootstrap = (ROOT / "Scripts/bootstrap.command").read_text()
        self.assertIn('"$SCRIPT_DIR/build-app.sh"', bootstrap)
        self.assertNotIn("brew install", bootstrap)
        self.assertNotIn("build-uxplay", bootstrap)
        self.assertNotIn("git clone", bootstrap)

    def test_app_build_supports_xcode_beta_and_command_line_tools(self):
        build_app = (ROOT / "Scripts/build-app.sh").read_text()
        self.assertIn("/Applications/Xcode-beta.app/Contents/Developer", build_app)
        self.assertIn("MIRRORLAB_DEVELOPER_DIR", build_app)
        self.assertIn("xcrun --find swiftc", build_app)
        self.assertIn("-parse-as-library", build_app)
        self.assertIn("-framework Network", build_app)
        self.assertIn("-framework Security", build_app)
        self.assertIn("MirrorLab-xcodebuild.log", build_app)
        self.assertIn("grep -n -B 2 -A 3 'error:'", build_app)

    def test_diagnostics_uses_explicit_self_in_dispatch_closure(self):
        diagnostics = (ROOT / "MirrorLab/Diagnostics.swift").read_text()
        self.assertIn("DispatchQueue.main.sync { self.events }", diagnostics)

    def test_diagnostics_snapshot_uses_one_pts_age_spelling(self):
        swift_sources = "\n".join(path.read_text() for path in (ROOT / "MirrorLab").rglob("*.swift"))
        self.assertNotIn("videoPTSageMS", swift_sources)
        self.assertGreaterEqual(swift_sources.count("videoPTSAgeMS"), 4)

    def test_metal_color_space_is_non_optional(self):
        source = (ROOT / "MirrorLab/USB/MetalVideoView.swift").read_text()
        self.assertIn("CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()", source)

    def test_build_failure_creates_visible_error_files(self):
        build_app = (ROOT / "Scripts/build-app.sh").read_text()
        self.assertIn('BUILD_LOG="$PROJECT_ROOT/MirrorLab-xcodebuild.log"', build_app)
        self.assertIn('ERROR_SUMMARY="$PROJECT_ROOT/MirrorLab-build-errors.txt"', build_app)

    def test_airplay_uses_dynamic_port_and_bonjour_actual_port(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("try NWListener(using: .tcp)", source)
        self.assertIn("listener?.port?.rawValue", source)
        self.assertNotIn("UInt16 = 7000", source)

    def test_usb_original_prioritizes_resolution_then_up_to_60fps(self):
        usb = (ROOT / "MirrorLab/USB/USBCaptureController.swift").read_text()
        ui = (ROOT / "MirrorLab/ContentView.swift").read_text()
        self.assertNotIn('Picker("USB FPS"', ui)
        self.assertIn("let preferredFPS = 60.0", usb)
        self.assertIn("if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }", usb)
        self.assertIn("let selectedFPS = min(preferredFPS, selected.1)", usb)

    def test_external_preview_window_is_standard_appkit_window(self):
        app = (ROOT / "MirrorLab/MirrorLabApp.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        self.assertNotIn('Window("MirrorLab Preview", id: "preview")', app)
        self.assertIn("ExternalPreviewView", content)
        self.assertIn("recordsDiagnostics: true", content)
        self.assertIn("CapturePreviewWindow(", model)
        self.assertIn("styleMask: [.borderless, .resizable, .miniaturizable]", model)
        self.assertIn("window.hasShadow = false", model)
        self.assertIn(".fullScreenPrimary", model)
        self.assertIn("PreviewInteractionView", model)
        self.assertIn("acceptsFirstMouse", model)
        self.assertIn("window.performDrag(with: event)", model)
        self.assertIn("PreviewControlsView", content)
        self.assertIn("togglePreviewControls", model)
        self.assertIn("rightMouseDown", model)
        self.assertIn("Скрыть элементы управления", model)
        self.assertNotIn("NSPanel(", model)
        self.assertIn("togglePreviewFullscreen()", model)
        self.assertNotIn("standardWindowButton(.zoomButton)", model)

    def test_external_preview_closes_with_transport_lifecycle(self):
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        airplay = (ROOT / "MirrorLab/WiFi" / "AirPlayController.swift").read_text()
        usb = (ROOT / "MirrorLab/USB/USBCaptureController.swift").read_text()
        self.assertIn("func closePreviewWindow()", model)
        self.assertIn("airplay.onFinalSessionEnded", model)
        self.assertIn("usb.onCaptureEnded", model)
        self.assertIn("applySelectedMode()", model)
        self.assertIn("onFinalSessionEnded?()", airplay)
        self.assertIn("AVCaptureSession.didStopRunningNotification", usb)
        self.assertIn("onCaptureEnded?()", usb)


    def test_external_preview_fans_out_frames(self):
        store = (ROOT / "MirrorLab/USB/LatestVideoFrameStore.swift").read_text()
        metal = (ROOT / "MirrorLab/USB/MetalVideoView.swift").read_text()
        self.assertIn("private var observers:", store)
        self.assertIn("addObserver", store)
        self.assertIn("removeObserver", store)
        self.assertIn("view.isPaused = true", metal)
        self.assertIn("view.enableSetNeedsDisplay = true", metal)
        self.assertIn("view.setNeedsDisplay", metal)

    def test_product_ui_has_only_airplay_and_usb_modes(self):
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        self.assertIn('case airplay = "AirPlay"', model)
        self.assertIn('case usb = "USB"', model)
        self.assertNotIn('case companion', model)
        self.assertNotIn('MirrorLab Direct', content)
        self.assertNotIn('Статус native rewrite', content)
        self.assertNotIn('AirPlay protocol trace', content)
        self.assertNotIn('Сохранить отчёт', content)

    def test_usb_is_automatic_in_usb_mode(self):
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        usb = (ROOT / "MirrorLab/USB/USBCaptureController.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        self.assertIn("usb.setAutomaticConnectionEnabled(true)", model)
        self.assertIn("Timer(timeInterval: 1.6, repeats: true)", usb)
        self.assertIn("automaticConnectionEnabled", usb)
        self.assertIn("selectedScreenDeviceID != nil", usb)
        self.assertNotIn('Запустить USB-экран', content)
        self.assertNotIn('Обновить USB-экраны', content)
        self.assertIn('controller.screenDevices.count > 1', content)
        self.assertNotIn('Picker("Устройство"', content)
        self.assertIn("presentUSBDeviceSelectionIfNeeded", model)
        self.assertIn('Menu("USB-источник")', (ROOT / "MirrorLab/MirrorLabApp.swift").read_text())

    def test_preview_is_primary_and_aspect_locked(self):
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        self.assertIn("window.contentAspectRatio", model)
        self.assertIn("airplayPresentationStore.currentDimensions()", model)
        self.assertIn("frameStore.currentDimensions()", model)
        self.assertIn("recordsDiagnostics: true", content)
        self.assertNotIn("private var preview: some View", content)

    def test_bootstrap_has_no_legacy_runtime_banner(self):
        bootstrap = (ROOT / "Scripts/bootstrap.command").read_text()
        self.assertNotIn("UxPlay", bootstrap)
        self.assertNotIn("GStreamer", bootstrap)
        self.assertNotIn("Homebrew", bootstrap)

    def test_embedded_playfair_provider_is_source_built_and_replaceable(self):
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        provider = (ROOT / "MirrorLab/WiFi/EmbeddedFairPlayProvider.swift").read_text()
        bridge = (ROOT / "Vendor/PlayFair/MirrorFairPlayBridge.c").read_text()
        build = (ROOT / "Scripts/build-fairplay.sh").read_text()

        for path in (
            ROOT / "Vendor/PlayFair/playfair.c",
            ROOT / "Vendor/PlayFair/omg_hax.c",
            ROOT / "Vendor/PlayFair/hand_garble.c",
            ROOT / "Vendor/PlayFair/modified_md5.c",
            ROOT / "Vendor/PlayFair/sap_hash.c",
            ROOT / "Vendor/PlayFair/PROVENANCE.md",
        ):
            self.assertTrue(path.exists(), path)

        self.assertIn("k_phase2_responses[4][142]", bridge)
        self.assertIn("playfair_decrypt", bridge)
        self.assertIn('"AirPlayStreamKey%llu"', bridge)
        self.assertIn('"AirPlayStreamIV%llu"', bridge)
        self.assertIn("kCCModeCTR", bridge)
        self.assertIn("kCCModeOptionCTR_BE", bridge)
        self.assertIn("dlopen", provider)
        self.assertIn("dlsym", provider)
        self.assertIn("libMirrorFairPlay.dylib", provider)
        self.assertIn("decryptSessionKey", provider)
        self.assertIn("prepareVideoCrypto", provider)
        self.assertIn("decryptVideo", provider)
        self.assertIn("build-fairplay.sh", (ROOT / "Scripts/build-app.sh").read_text())
        self.assertIn("-dynamiclib", build)
        self.assertIn("EmbeddedFairPlayProvider", controller)
        self.assertNotIn("FairPlayInterop", controller)

    def test_playfair_bridge_supports_all_four_legacy_modes(self):
        bridge = (ROOT / "Vendor/PlayFair/MirrorFairPlayBridge.c").read_text()
        self.assertIn("static const uint8_t k_phase2_responses[4][142]", bridge)
        self.assertIn("const uint8_t mode = request[14]", bridge)
        self.assertIn("if (mode > 3)", bridge)
        self.assertIn("memcpy(response, k_phase2_responses[mode], 142)", bridge)
        # Every record starts with FPLY 3.1 phase 2 and embeds its own mode at byte 13.
        blocks = bridge.split("static const uint8_t k_phase2_responses[4][142] = {", 1)[1].split("};", 1)[0]
        for mode in range(4):
            token = f"0x02, 0x{mode:02X},"
            self.assertIn(token, blocks)

    def test_airplay_video_ctr_is_not_rewound_by_repeated_setup(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("preparedVideoStreamID", source)
        self.assertIn(
            "if preparedVideoStreamID == activeStreamConnectionID && fairPlay.isVideoCryptoReady",
            source,
        )
        self.assertIn("preparedVideoStreamID = activeStreamConnectionID", source)
        self.assertIn("preparedVideoStreamID = nil", source)

    def test_airplay_video_pipeline_is_fairplay_to_videotoolbox_to_metal(self):
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        decoder = (ROOT / "MirrorLab/WiFi/AirPlayVideoDecoder.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        build = (ROOT / "Scripts/build-app.sh").read_text()

        for token in (
            "fairPlay.decryptSessionKey",
            "fairPlay.prepareVideoCrypto",
            "fairPlay.decryptVideo",
            "videoDecoder.configure",
            "videoDecoder.decode",
            "videoDecodedFrames",
        ):
            self.assertIn(token, controller)

        for token in (
            "CMVideoFormatDescriptionCreateFromH264ParameterSets",
            "VTDecompressionSessionCreate",
            "kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder",
            "kVTDecompressionPropertyKey_RealTime",
            "VTDecompressionSessionDecodeFrame",
            "presentationStore.enqueue",
        ):
            self.assertIn(token, decoder)
        self.assertIn("-framework VideoToolbox", build)
        self.assertIn("MetalVideoView", content)

    def test_airplay_mirror_header_uses_type_subtype_and_little_endian_options(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        for token in (
            "let payloadType: UInt8",
            "let payloadSubtype: UInt8",
            "let payloadOption: UInt16",
            "let payloadType = b[offset + 4]",
            "let payloadSubtype = b[offset + 5]",
            "UInt16(b[offset + 6]) | (UInt16(b[offset + 7]) << 8)",
            "header.payloadSubtype == 0x10",
            "header.payloadOption == 0x0006",
        ):
            self.assertIn(token, source)

    def test_airplay_realtime_audio_type96_transport_is_native(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        for token in (
            "startAudioListenersAndReply",
            "try NWListener(using: .udp)",
            '"controlPort": Int(controlPort)',
            '"dataPort": Int(dataPort)',
            '"type": 96',
            'streamReply["streamConnectionID"] = connectionID',
            "audioPacketsReceived",
            "receiveMessage",
        ):
            self.assertIn(token, source)
        self.assertNotIn('audio transport будет следующим слоем', source)

    def test_airplay_mirror_packet_parser_and_crypto_diagnostics_are_present(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        for token in (
            "parseMirrorPackets",
            "let headerSize = 128",
            "mirrorVideoPackets",
            "mirrorCodecPackets",
            "mirrorHeartbeatPackets",
            "mirrorMalformedPackets",
            "describeAVCConfiguration",
            "fairPlayKeyMessageHex",
            "setupCryptoSummary",
            "streamConnectionID",
        ):
            self.assertIn(token, source)


    def test_airplay_mirror_parser_is_bounded_and_does_not_byte_spam_main_queue(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("maximumMirrorBufferedBytes", source)
        self.assertIn("findNextPlausibleMirrorHeader", source)
        self.assertIn("reportMirrorDesync", source)
        self.assertIn("scanLimit: min(buffer.count - headerSize + 1, 64 * 1024)", source)
        self.assertNotIn("buffer.removeFirst(1)", source)
        # Regression: malformed input may scan bytes for a plausible header, but it must
        # never enqueue a UI task or mutate the Data buffer once per rejected byte.
        parser = source[source.index("private func parseMirrorPackets"):source.index("private func compactStreamDescription")]
        self.assertNotIn("removeFirst(1)", parser)
        self.assertNotIn("removeSubrange(0..<1)", parser)
        self.assertIn("buffer.removeSubrange(0..<offset)", parser)
        self.assertIn("mirrorDesyncReports", source)

    def test_airplay_feedback_heartbeat_is_suppressed_from_event_spam(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("feedbackHeartbeatCount", source)
        self.assertIn('request.method == "POST" && route == "/feedback"', source)
        self.assertIn("POST /feedback heartbeat #", source)
        self.assertIn("return", source[source.index('request.method == "POST" && route == "/feedback"'):source.index("let bodyPrefix")])

    def test_airplay_pending_audio_setup_is_deduplicated(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("pendingAudioSetupReply:", source)
        self.assertNotIn("pendingAudioSetupReplies:", source)
        self.assertNotIn("pendingAudioSetupReplies.append", source)

    def test_gpl_source_distribution_contract_is_documented(self):
        license_text = (ROOT / "LICENSE").read_text()
        notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text()
        provenance = (ROOT / "Vendor/PlayFair/PROVENANCE.md").read_text()
        self.assertIn("GNU GENERAL PUBLIC LICENSE", license_text)
        self.assertIn("PlayFair", notices)
        self.assertIn("GNU GPL v3", notices)
        self.assertIn("EstebanKubata", provenance)
        self.assertIn("9e402cc8025e64120339e7f3138b6b876ffca52f", provenance)

    def test_airplay_teardown_keeps_control_session_for_stream_reconfiguration(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("handleTeardown(", source)
        self.assertIn("TEARDOWN streams=", source)
        self.assertIn("teardownMirrorStreamForReconfiguration", source)
        self.assertNotIn('case ("TEARDOWN", _):\n            send(response: AirPlayResponse.ok(request: request), over: connection)\n            connection.cancel()', source)


    def test_airplay_single_active_source_generation_contract(self):
        source = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("sessionGeneration", source)
        self.assertIn("activeControlConnectionID", source)
        self.assertIn("beginSessionTakeoverIfNeeded", source)
        self.assertIn("STALE TEARDOWN ignored", source)
        self.assertIn("mirrorConnectionGenerations", source)
        self.assertIn("generation == self.sessionGeneration", source)

    def test_airplay_preview_observes_live_video_state(self):
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        self.assertIn("if !model.airplay.hasLiveVideo", content)
        self.assertIn("airplay.$hasLiveVideo", model)
        self.assertIn("self.showPreviewWindow()", model)

    def test_airplay_has_dedicated_zero_copy_display_link_renderer(self):
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        airplay_metal = (ROOT / "MirrorLab/WiFi/AirPlayMetalVideoView.swift").read_text()
        usb_metal = (ROOT / "MirrorLab/USB/MetalVideoView.swift").read_text()

        self.assertIn("AirPlayMetalVideoView", content)
        for token in (
            "CVMetalTextureCacheCreate",
            "CVMetalTextureCacheCreateTextureFromImage",
            "CVMetalTextureGetTexture",
            "CAMetalDisplayLink(metalLayer: layer)",
            "preferredFrameRateRange",
            "preferredFrameLatency = 1.0",
            "update.drawable",
            "commandBuffer.present(drawable)",
            "layer.framebufferOnly = true",
            "nv12_video_fragment",
            "BT.709",
        ):
            self.assertIn(token, airplay_metal)
        self.assertNotIn("CIContext", airplay_metal)
        self.assertNotIn("view.setNeedsDisplay", airplay_metal)

        # Regression: USB remains on the proven input-driven CoreImage path.
        self.assertIn("CIContext", usb_metal)
        self.assertIn("view.isPaused = true", usb_metal)
        self.assertIn("view.setNeedsDisplay", usb_metal)


    def test_airplay_uses_real_ntp_timestamps_and_jitter_buffer(self):
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        renderer = (ROOT / "MirrorLab/WiFi/AirPlayMetalVideoView.swift").read_text()
        diagnostics = (ROOT / "MirrorLab/Diagnostics.swift").read_text()

        for token in (
            "mirrorTimestampNanoseconds",
            "header.timestampRaw",
            "recordAirPlaySourceFrame",
            "timescale: 1_000_000_000",
        ):
            self.assertIn(token, controller)
        self.assertIn("struct AirPlayPlayoutClock", renderer)
        self.assertIn("frameForPresentation", renderer)
        self.assertIn("catchUpThreshold", renderer)
        self.assertIn("presentationStore.enqueue", (ROOT / "MirrorLab/WiFi/AirPlayVideoDecoder.swift").read_text())
        self.assertIn("sourceFrameJitterMS", diagnostics)
        self.assertIn("presentationDroppedFrames", diagnostics)

    def test_0310_timestamp_scheduler_restores_golden_layer_owned_display_clock(self):
        renderer = (ROOT / "MirrorLab/WiFi/AirPlayMetalVideoView.swift").read_text()
        decoder = (ROOT / "MirrorLab/WiFi/AirPlayVideoDecoder.swift").read_text()
        self.assertIn("clock.scheduledHostTime(sourceSeconds:", renderer)
        self.assertIn("frameForPresentation", renderer)
        self.assertIn("presentationStore.enqueue", decoder)
        self.assertIn("CAMetalDisplayLink(metalLayer: layer)", renderer)
        self.assertIn("link.add(to: .main, forMode: .common)", renderer)
        self.assertIn("update.drawable", renderer)
        self.assertNotIn("CVDisplayLinkCreateWithActiveCGDisplays", renderer)
        self.assertNotIn("CFRunLoopRun", renderer)
        self.assertNotIn("display-link watchdog", renderer)

    def test_airplay_audio_is_pcm_realtime_not_media_renderer(self):
        audio = (ROOT / "MirrorLab/WiFi/AirPlayLowLatencyAudioPlayer.swift").read_text()
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        for token in ("AVAudioConverter", "primeMethod = .none", "kAudioUnitSubType_DefaultOutput", "InterleavedPCMFrameRing"):
            self.assertIn(token, audio)
        self.assertNotIn("AVSampleBufferAudioRenderer", audio)
        self.assertNotIn('"audioBufferSize": 8 * 1024 * 1024', controller)
        self.assertIn("decryptAudioCBC", controller)


    def test_airplay_realtime_stages_are_off_main_and_external_preview_is_non_destructive(self):
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        renderer = (ROOT / "MirrorLab/WiFi/AirPlayMetalVideoView.swift").read_text()
        diagnostics = (ROOT / "MirrorLab/Diagnostics.swift").read_text()

        self.assertIn('MirrorLab.NativeAirPlay.ControlVideo', controller)
        self.assertIn('MirrorLab.NativeAirPlay.AudioTransport', controller)
        self.assertIn('MirrorLab.NativeAirPlay.Telemetry', controller)
        self.assertIn('startTelemetryPublisher()', controller)
        self.assertIn('repeating: .milliseconds(250)', controller)
        self.assertIn('frameForObserver', renderer)
        self.assertIn('recordsDiagnostics', renderer)
        self.assertIn('CAMetalDisplayLink(metalLayer: layer)', renderer)
        self.assertIn('preferredFrameRateRange', renderer)
        self.assertIn('link.add(to: .main, forMode: .common)', renderer)
        self.assertNotIn('CVDisplayLinkCreateWithActiveCGDisplays', renderer)
        self.assertNotIn('CFRunLoopRun', renderer)
        self.assertIn('MirrorLab.Diagnostics.Publish', diagnostics)
        self.assertIn('DispatchSource.makeTimerSource', diagnostics)

    def test_airplay_forward_pts_discontinuity_reanchors_before_queue_deadlock(self):
        renderer = (ROOT / "MirrorLab/WiFi/AirPlayMetalVideoView.swift").read_text()
        # 0.3.49: forward/backward PTS jumps no longer need a 180 ms queue-clearing
        # reset. The sliding-minimum base re-anchors within the 3 s window, a big excess
        # snaps instead of overflowing the queue, and only a >10 s clock jump clears it.
        self.assertIn("static let snapThreshold: TimeInterval = 0.150", renderer)
        self.assertIn("static let discontinuityThreshold: TimeInterval = 10.0", renderer)
        self.assertIn("Int((clock.mode.maximumDelay * 60).rounded(.up)) + 12", renderer)
        self.assertNotIn("timelineResetThreshold", renderer)
        self.assertNotIn("scheduled - arrival > 1.0", renderer)


    def test_0332_adds_airplay_quality_fps_modes_and_audio_margin_metrics(self):
        renderer = (ROOT / "MirrorLab/WiFi/AirPlayMetalVideoView.swift").read_text()
        audio = (ROOT / "MirrorLab/WiFi/AirPlayLowLatencyAudioPlayer.swift").read_text()
        self.assertIn("CAMetalDisplayLink(metalLayer: layer)", renderer)
        self.assertIn("preferredFrameRateRange", renderer)
        self.assertIn("hostTime: update.targetPresentationTimestamp", renderer)
        self.assertIn("render(frame: frame, drawable: update.drawable)", renderer)
        self.assertIn("struct AirPlayAudioBufferPolicy", audio)
        self.assertIn("preroll = 0.045; floor = 0.015; cap = 0.220", audio)
        self.assertIn("(policy.preroll + adaptiveMargin) * sampleRate", audio)
        controller = (ROOT / "MirrorLab" / "WiFi" / "AirPlayController.swift").read_text()
        decoder = (ROOT / "MirrorLab" / "WiFi" / "AirPlayVideoDecoder.swift").read_text()
        self.assertIn("baseFeatureBits: UInt64 = 0x0000001E527FFFF7", controller)
        self.assertIn("screenMultiCodecBit: UInt64 = 1 << 42", controller)
        self.assertIn('return String(format: "0x%08X,0x%X", low, high)', controller)
        self.assertIn('case hd720 = "720p"', controller)
        self.assertIn('case fullHD = "Full HD"', controller)
        self.assertIn('case original = "Original"', controller)
        self.assertIn("bootstrap-awaiting-device-model", controller)
        self.assertIn("activeSourceModelIdentifier", controller)
        self.assertIn("nativeDisplayProfile(for model:", controller)
        self.assertIn('root["model"] as? String', controller)
        self.assertIn("requested_video_strategy", controller)
        self.assertIn("source_model_identifier", controller)
        self.assertIn("case \"iPhone18,4\"", controller)
        self.assertIn("case \"iPad16,5\"", controller)
        self.assertIn("case fps30 = 30", controller)
        self.assertIn("case fps60 = 60", controller)
        self.assertIn("requestedWidth", controller)
        self.assertIn("requestedHeight", controller)
        self.assertIn("configure(codecConfig:", controller)
        self.assertIn("CMVideoFormatDescriptionCreateFromHEVCParameterSets", decoder)
        self.assertIn("parseHEVCConfiguration", decoder)
        self.assertIn("extractHVCCFromSampleEntry", decoder)
        self.assertIn('type == "hvc1" || type == "hev1"', decoder)
        self.assertIn("MirrorReceiveState", controller)
        self.assertIn("var cursor = 0", controller)
        self.assertIn("video_packet_max_arrival_gap_ms", controller)
        self.assertIn("decoded_frame_max_gap_ms", controller)
        ui = (ROOT / "MirrorLab" / "ContentView.swift").read_text()
        diagnostics = (ROOT / "MirrorLab" / "Diagnostics.swift").read_text()
        self.assertIn('GroupBox("Видео")', ui)
        self.assertIn("$controller.videoQuality", ui)
        self.assertIn("$controller.preferredFrameRate", ui)
        self.assertIn("audioUnderflowEvents", diagnostics)
        self.assertIn("audioOverflowTrimEvents", diagnostics)
        self.assertIn("audioConverterFailures", diagnostics)

    def test_0340_clean_capture_preview_and_window_tab_hardening(self):
        app = (ROOT / "MirrorLab/MirrorLabApp.swift").read_text()
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        self.assertIn("NSWindow.allowsAutomaticWindowTabbing = false", app)
        self.assertIn("window.tabbingMode = .disallowed", model)
        self.assertIn('"toggleTabBar:"', model)
        self.assertIn('"showAllTabs:"', model)
        self.assertIn("styleMask: [.borderless, .resizable, .miniaturizable]", model)
        self.assertIn("window.hasShadow = false", model)
        self.assertIn('window.title = previewWindowTitle', model)
        self.assertIn("PreviewInteractionView", model)
        self.assertIn("override var canBecomeKey: Bool { true }", model)
        self.assertNotIn("NSPanel(", model)
        self.assertIn("PreviewControlsView", content)
        self.assertIn("controlsHosting.isHidden", model)

    def test_0340_system_receiver_name_and_preview_navigation(self):
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        self.assertIn("Host.current().localizedName", controller)
        self.assertNotIn("MirrorLab — Вова", controller)
        self.assertNotIn('TextField("Имя"', content)
        self.assertIn("Text(controller.receiverName)", content)
        self.assertIn("Показать предпросмотр", content)
        self.assertIn("showSettingsWindow()", model)
        self.assertIn("isPreviewVisible", model)

    def test_0340_usb_multi_device_selection_is_explicit(self):
        usb = (ROOT / "MirrorLab/USB/USBCaptureController.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        self.assertNotIn("MirrorLabPreferredUSBScreenDeviceID", usb)
        self.assertNotIn("UserDefaults.standard", usb)
        self.assertIn("deviceSetChanged", usb)
        self.assertIn("selectedScreenDeviceID = screenDevices.count == 1 ? screenDevices[0].id : nil", usb)
        self.assertIn("detectDeviceSetChangeWhileRunning", usb)
        self.assertIn("screenDevices.count > 1", content)
        self.assertNotIn('Picker("Устройство"', content)

    def test_0340_presentation_drop_counter_resets_per_airplay_session(self):
        renderer = (ROOT / "MirrorLab/WiFi/AirPlayMetalVideoView.swift").read_text()
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("func resetForNewSession()", renderer)
        self.assertIn("droppedFrames = 0", renderer)
        self.assertGreaterEqual(controller.count("presentationStore.resetForNewSession()"), 2)


    def test_0343_preview_minimize_and_clean_controls_hotfix(self):
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        self.assertIn("styleMask: [.borderless, .resizable, .miniaturizable]", model)
        self.assertIn("window.styleMask.insert(.miniaturizable)", model)
        self.assertIn("window.miniaturize(nil)", model)
        self.assertIn("window.orderOut(nil)", model)
        self.assertIn("if model.previewControlsVisible", content)
        self.assertIn("previewControlsHostingView?.alphaValue", model)
        self.assertIn("previewControlsHostingView?.layer?.isHidden", model)

    def test_0344_mirror_only_video_advertisement_and_audio_loss_recovery(self):
        airplay = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        audio = (ROOT / "MirrorLab/WiFi/AirPlayLowLatencyAudioPlayer.swift").read_text()
        diagnostics = (ROOT / "MirrorLab/Diagnostics.swift").read_text()

        # YouTube must see a screen-mirroring receiver, not an unimplemented
        # direct Video/HLS target. Screen/Audio bits remain in the legacy mask;
        # direct-video bits are explicitly cleared before Bonjour and /info.
        self.assertIn("directVideoFeatureMask", airplay)
        self.assertIn("UInt64(1) << 0", airplay)
        self.assertIn("UInt64(1) << 4", airplay)
        self.assertIn("UInt64(1) << 33", airplay)
        self.assertIn("baseFeatureBits & ~directVideoFeatureMask", airplay)
        self.assertIn('case ("GET", "/server-info")', airplay)
        self.assertIn("video_advertisement_policy", airplay)

        # Normal ordered AAC-ELD remains immediate. Detected holes wait only on
        # the loss path; 0.3.47 adds real RTP control-port resend recovery and
        # faded concealment for the rare packet that still cannot be recovered.
        self.assertIn("reorderWindowPackets: UInt16 = 6", audio)
        self.assertIn("pendingPackets", audio)
        self.assertIn("onResendRequest", audio)
        self.assertIn("recordAirPlayAudioLateRecovery", audio)
        self.assertIn("recordAirPlayAudioConcealment", audio)
        self.assertIn("ring.writeConcealment", audio)
        self.assertIn("audioLateRecoveredPackets", diagnostics)
        self.assertIn("audioConcealedFrames", diagnostics)

    def test_0345_airplay_audio_control_resend_and_music_stability(self):
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        audio = (ROOT / "MirrorLab/WiFi/AirPlayLowLatencyAudioPlayer.swift").read_text()
        diagnostics = (ROOT / "MirrorLab/Diagnostics.swift").read_text()

        self.assertIn("audioResendConnection", controller)
        self.assertIn("configureAudioResendTransport", controller)
        self.assertIn("sendAudioResendRequest", controller)
        self.assertIn("bytes[1] = 0xD5", controller)
        self.assertIn("isRetransmissionDatagram", controller)
        self.assertIn("parseRTP(data, base: 4)", controller)
        self.assertIn("recordAirPlayAudioResendRequest", controller)
        self.assertIn("recordAirPlayAudioRetransmittedPacket", controller)
        self.assertIn("policy.cap * sampleRate", audio)
        self.assertIn("writeConcealment", audio)
        self.assertIn("fadeInPending", audio)
        self.assertIn("audioResendRequests", diagnostics)
        self.assertIn("audioRetransmittedPackets", diagnostics)

    def test_version_and_transport_mode_contract(self):
        self.assertEqual((ROOT / "VERSION").read_text().strip(), "0.3.50")
        app_model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        self.assertIn('case airplay = "AirPlay"', app_model)
        self.assertIn('case usb = "USB"', app_model)
        self.assertNotIn('case companion', app_model)


    def test_0334_airplay_autostart_usb_native_format_and_direct_coreaudio(self):
        model = (ROOT / "MirrorLab" / "AppModel.swift").read_text()
        airplay = (ROOT / "MirrorLab" / "WiFi" / "AirPlayController.swift").read_text()
        usb = (ROOT / "MirrorLab" / "USB" / "USBCaptureController.swift").read_text()
        audio = (ROOT / "MirrorLab" / "USB" / "SampleBufferAudioPlayer.swift").read_text()
        ui = (ROOT / "MirrorLab" / "ContentView.swift").read_text()

        self.assertIn("enableAutomaticReceiver()", model)
        self.assertNotIn("model.airplay.stop()", ui)
        self.assertIn("scheduleSettingsRestart()", airplay)
        self.assertNotIn('Остановить AirPlay', ui)
        self.assertNotIn('Запустить AirPlay', ui)
        self.assertNotIn("session.sessionPreset = .inputPriority", usb)
        self.assertIn("device.activeFormat = selected.0", usb)
        self.assertIn("AVCaptureVideoDataOutput device-native samples", usb)
        self.assertIn('"available_formats": availableFormatInventory()', usb)
        self.assertIn("videoOutput.videoSettings = [:]", usb)
        self.assertIn("let iosScreenDevices = devices.filter(Self.isLikelyIOSScreenDevice)", usb)
        self.assertNotIn("?? screenDevices.first?.id", usb)
        self.assertIn("guard Self.isLikelyIOSScreenDevice(device) else", usb)
        self.assertIn("camera_privacy_classification", usb)
        self.assertIn("kCMIOStreamPropertyPreferredFormatDescription", usb)
        self.assertIn("kCMIOStreamPropertyStillImageFormatDescriptions", usb)
        usb_decoder = (ROOT / "MirrorLab" / "USB" / "USBVideoSampleDecoder.swift").read_text()
        self.assertIn("VTDecompressionSessionCreate", usb_decoder)
        self.assertIn("kCMVideoCodecType_HEVC", usb_decoder)
        self.assertIn("CMSampleBufferCopyPCMDataIntoAudioBufferList", audio)
        self.assertIn("kAudioUnitSubType_DefaultOutput", audio)
        self.assertNotIn("AVSampleBufferAudioRenderer", audio)
        self.assertNotIn("AVSampleBufferRenderSynchronizer", audio)

    def test_0341_transport_lifecycle_permission_and_stop_controls(self):
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        usb = (ROOT / "MirrorLab/USB/USBCaptureController.swift").read_text()
        airplay = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        self.assertIn("airplay.stop()", model)
        self.assertIn("airplay.enableAutomaticReceiver()", model)
        self.assertIn("stopCurrentSessionKeepingReceiver", airplay)
        self.assertIn("Прекратить трансляцию", content)
        self.assertIn("case permissionDenied", usb)
        self.assertIn("openCameraPrivacySettings", usb)
        self.assertIn("NSApplication.didBecomeActiveNotification", content)
        self.assertIn("resumeAutomaticCapture", usb)

    def test_0341_receiver_name_cache_migration_is_explicit(self):
        airplay = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("loadOrCreate(receiverName:", airplay)
        self.assertIn("MirrorLab.AirPlay.IdentityNamingVersion", airplay)
        self.assertIn("MirrorLab.AirPlay.LastReceiverName", airplay)
        self.assertIn('defaults.removeObject(forKey: "MirrorLab.AirPlay.DeviceID")', airplay)
        self.assertIn('defaults.removeObject(forKey: "MirrorLab.AirPlay.PublicIdentifier")', airplay)

    def test_0342_preview_context_menu_controls_and_aspect_locked_resize(self):
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        self.assertIn("override func rightMouseDown", model)
        self.assertIn("Скрыть элементы управления", model)
        self.assertIn("Показать элементы управления", model)
        self.assertIn("togglePreviewControls()", model)
        self.assertIn("let height = width / ratio", model)
        self.assertIn("window.contentAspectRatio = NSSize(width: ratio, height: 1)", model)
        self.assertIn('Label("Прекратить", systemImage: "stop.fill")', content)
        self.assertIn(".buttonStyle(.bordered)", content)

    def test_housekeeping_layout_and_bootstrap_autoclose(self):
        self.assertTrue((ROOT / "docs" / "ReleaseNotes" / "RELEASE_NOTES_0.3.48_RU.md").exists())
        self.assertTrue((ROOT / "docs" / "ReleaseNotes" / "RELEASE_NOTES_0.3.49_RU.md").exists())
        self.assertTrue((ROOT / "docs" / "ReleaseNotes" / "RELEASE_NOTES_0.3.50_RU.md").exists())
        self.assertFalse(any(ROOT.glob("RELEASE_NOTES_*_RU.md")))
        self.assertTrue((ROOT / "Tools" / "Diagnostics" / "LatencyTest" / "index.html").exists())
        latency_script = (ROOT / "Scripts" / "run-latency-test.command").read_text()
        self.assertIn("Tools/Diagnostics/LatencyTest", latency_script)
        bootstrap = (ROOT / "Scripts" / "bootstrap.command").read_text()
        self.assertIn("close_own_terminal_tab_after_exit", bootstrap)
        self.assertNotIn("read -r -p 'Нажми Enter, чтобы закрыть окно…'", bootstrap.split('"$SCRIPT_DIR/build-app.sh"', 1)[1])

    def test_0348_preview_volume_controls_both_audio_transports(self):
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()
        usb_controller = (ROOT / "MirrorLab/USB/USBCaptureController.swift").read_text()
        usb_audio = (ROOT / "MirrorLab/USB/SampleBufferAudioPlayer.swift").read_text()
        airplay_controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        airplay_audio = (ROOT / "MirrorLab/WiFi/AirPlayLowLatencyAudioPlayer.swift").read_text()

        self.assertIn('MirrorLab.OutputVolume', model)
        self.assertIn('return 0.65', model)
        self.assertIn('airplay.setOutputVolume(Float(clamped))', model)
        self.assertIn('usb.setOutputVolume(Float(clamped))', model)
        self.assertIn('Slider(value: $model.outputVolume, in: 0...1)', content)
        self.assertIn('PreviewControlButton(systemName: volumeSymbol, help: "Громкость")', content)
        # Volume button must remain after close, i.e. the right-most Preview control.
        self.assertLess(content.index('help: "Закрыть предпросмотр"'), content.index('help: "Громкость"'))
        self.assertIn('func setOutputVolume(_ volume: Float)', usb_controller)
        self.assertIn('func setOutputVolume(_ volume: Float)', airplay_controller)
        self.assertIn('gain: self.outputVolume', usb_audio)
        self.assertIn('gain: outputVolume', airplay_audio)
        self.assertIn('* gain', usb_audio)
        self.assertIn('* gain', airplay_audio)

    def test_0347_release_icon_and_russian_localization_assets_present(self):
        self.assertTrue((ROOT / "MirrorLab/Resources/MirrorLab.icns").exists())
        self.assertTrue((ROOT / "MirrorLab/Resources/ru.lproj/InfoPlist.strings").exists())

    def test_0347_wake_reanchor_is_not_aggressive(self):
        text = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("resumeGapMS >= 2_000", text)
        self.assertNotIn("resumeGapMS > 650", text)
        audio = (ROOT / "MirrorLab/WiFi/AirPlayLowLatencyAudioPlayer.swift").read_text()
        self.assertNotIn("softLeadCeilingFrames", audio)
        self.assertNotIn("prepareForTransportReconfiguration", audio)


    def test_0349_adaptive_wifi_playout_buffer(self):
        renderer = (ROOT / "MirrorLab/WiFi/AirPlayMetalVideoView.swift").read_text()
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()

        # One-frame anchor (+40 ms) is gone; the delay is measured from every frame.
        self.assertNotIn("targetLatency: TimeInterval = 0.040", renderer)
        self.assertNotIn("sourceAnchorSeconds", renderer)
        self.assertNotIn("hostAnchorSeconds", renderer)
        for token in (
            "enum AirPlayBufferMode",
            'case lowLatency = "low-latency"',
            'case balanced = "balanced"',
            'case smooth = "smooth"',
            "struct AirPlayPlayoutClock",
            "static let window: TimeInterval = 3.0",
            "coveredFraction",
            "peakHold",
            "holdPeak(",
            "static let growDeadband",
            "static let shrinkPerFrame: TimeInterval = 0.0005",
            "func setBufferMode(_ mode: AirPlayBufferMode)",
            "clock.reset(keepingDelayEstimate: true)",
            "clock.reset(keepingDelayEstimate: false)",
            "hostTime: update.targetPresentationTimestamp",
        ):
            self.assertIn(token, renderer, token)

        # Renderers remember the last drawn sequence; it must never restart at 0.
        reset = renderer[renderer.index("func resetForNewSession()"):renderer.index("func state()")]
        self.assertNotIn("nextSequence = 0", reset)

        self.assertIn("@Published var bufferMode: AirPlayBufferMode", controller)
        self.assertIn('"MirrorLab.AirPlay.BufferMode"', controller)
        self.assertIn("presentationStore.setBufferMode(bufferMode)", controller)
        for key in ("video_buffer_mode", "video_playout_delay_ms", "video_wifi_jitter_ms", "video_late_frames"):
            self.assertIn(f'"{key}"', controller)
        self.assertIn('Picker("Буфер Wi-Fi", selection: $controller.bufferMode)', content)

    def test_0349_mirror_parser_trusts_tcp_framing(self):
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("strict: Bool = true", controller)
        self.assertIn("Self.isPlausibleMirrorHeader(header, maximumPayload: maximumPayload, strict: false)", controller)
        self.assertIn("private static let maximumMirrorPayloadBytes = 16 * 1024 * 1024", controller)
        self.assertIn("AirPlayController.maximumMirrorPayloadBytes + 512 * 1024", controller)
        self.assertNotIn("let maximumPayload = 32 * 1024 * 1024", controller)
        self.assertNotIn("maximumMirrorBufferedBytes = 8 * 1024 * 1024", controller)
        self.assertIn("accepted by length", controller)

    def test_0349_mirror_socket_marks_interactive_video(self):
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        self.assertIn("mirrorParameters.serviceClass = .interactiveVideo", controller)
        self.assertIn("try NWListener(using: mirrorParameters)", controller)

    def test_0349_streaming_activity_prevents_app_nap_and_display_sleep(self):
        model = (ROOT / "MirrorLab/AppModel.swift").read_text()
        for token in (
            "private var streamingActivity: NSObjectProtocol?",
            "ProcessInfo.processInfo.beginActivity(",
            ".latencyCritical",
            ".idleDisplaySleepDisabled",
            "ProcessInfo.processInfo.endActivity(activity)",
            "self.updateStreamingActivity(airplayLive: live)",
            "self.updateStreamingActivity(usbPhase: phase)",
        ):
            self.assertIn(token, model, token)


    def test_0350_audio_latency_fixes(self):
        audio = (ROOT / "MirrorLab/WiFi/AirPlayLowLatencyAudioPlayer.swift").read_text()
        controller = (ROOT / "MirrorLab/WiFi/AirPlayController.swift").read_text()
        content = (ROOT / "MirrorLab/ContentView.swift").read_text()

        # Silence packets keep RTP sequencing instead of being dropped up front.
        self.assertNotIn("if packet.payload == Data([0x00, 0x68, 0x34, 0x00]) { return }", controller)
        self.assertIn("audioPlayer.enqueueSilenceMarker(rtpTimestamp: packet.timestamp, sequence: packet.sequence)", controller)
        self.assertIn("func enqueueSilenceMarker(", audio)
        self.assertIn("ring.noteSilence()", audio)
        self.assertIn("silenceActive", audio)

        # Concealment only restores the preroll cushion; long holes are not padded.
        self.assertIn("maximumConcealedPackets = 8", audio)
        self.assertIn("max(0, startupFrames - ring.availableFrames)", audio)
        self.assertNotIn("max(0, maxLeadFrames - ring.availableFrames)", audio)

        # Surplus PCM is drained; underruns add decaying adaptive margin.
        for token in (
            "struct PacketWindowMinimum",
            "floorWindow.push(availableBefore)",
            "compressFrames(",
            "updateAdaptiveMargin(ring:",
            "func setLatencyMode(_ mode: AirPlayBufferMode)",
            "withExtendedLifetime(pcm)",
        ):
            self.assertIn(token, audio, token)
        self.assertIn("audioPlayer.setLatencyMode(bufferMode)", controller)

        # Output device latency is measured and surfaced.
        for token in (
            "enum AirPlayAudioOutputProbe",
            "kAudioOutputUnitProperty_CurrentDevice",
            "kAudioDevicePropertyTransportType",
            "kAudioDevicePropertyLatency",
            "kAudioDevicePropertySafetyOffset",
            "kAudioStreamPropertyLatency",
            "kAudioDeviceTransportTypeBluetooth",
            "kAudioDeviceTransportTypeAirPlay",
            "kAudioDevicePropertyBufferFrameSize",
        ):
            self.assertIn(token, audio, token)
        self.assertIn("controller.audioOutputWarning", content)
        self.assertIn("controller.audioOutputSummary", content)

        # Report fields that split audio latency into its parts.
        for key in (
            "audio_receiver_lead_ms",
            "audio_receiver_floor_ms",
            "audio_output_latency_ms",
            "audio_output_transport",
            "audio_sender_latency_ms",
            "audio_video_arrival_skew_ms",
        ):
            self.assertIn(f'"{key}"', controller, key)
        self.assertIn("static func isSyncDatagram", controller)
        self.assertIn("recordAudioSync(data)", controller)


if __name__ == "__main__":
    unittest.main(verbosity=2)
