// rc-audio: what the Mac plays, for Remote Cut's live monitor (the Mac twin of premiere-plugin/loopback.cs).
// Captures the system audio with ScreenCaptureKit (macOS 13+) and writes the same stream as the Windows
// helper: one header line "rate channels bits", then interleaved float32 PCM on stdout. It runs as a child
// of Premiere's panel, so it uses Premiere's Screen Recording permission (the same one the video needs).
// Exits when stdout closes (the panel stopped) or the parent goes away.
//
// Build (macOS, see .github/workflows/build.yml):
//   swiftc -O -target arm64-apple-macos13 rc-audio.swift -o rc-audio-arm64
//   swiftc -O -target x86_64-apple-macos13 rc-audio.swift -o rc-audio-x64
//   lipo -create rc-audio-arm64 rc-audio-x64 -output rc-audio && codesign -s - rc-audio
import Foundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit

let version = "1.0.0"
if CommandLine.arguments.contains("--version") { print("rc-audio \(version)"); exit(0) }

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(("rc-audio: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

// Writes everything or ends the process: a closed pipe means the panel no longer wants audio.
func emit(_ bytes: UnsafeRawPointer, _ count: Int) {
    var done = 0
    while done < count {
        let n = write(STDOUT_FILENO, bytes + done, count - done)
        if n <= 0 { if errno == EINTR { continue }; exit(0) }
        done += n
    }
}

final class AudioOut: NSObject, SCStreamOutput, SCStreamDelegate {
    var headerSent = false
    var interleaved = [Float]()

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid,
              let desc = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }
        let channels = Int(asbd.mChannelsPerFrame), frames = CMSampleBufferGetNumSamples(buffer)
        guard channels > 0, frames > 0, asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        if !headerSent {
            let header = "\(Int(asbd.mSampleRate)) \(channels) 32\n"
            header.withCString { emit($0, strlen($0)) }
            headerSent = true
        }
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        try? buffer.withAudioBufferList { list, _ in
            if !planar {
                guard let data = list[0].mData else { return }
                emit(data, Int(list[0].mDataByteSize))
                return
            }
            // ScreenCaptureKit hands one buffer per channel: interleave them (L R L R ...).
            if interleaved.count != frames * channels { interleaved = [Float](repeating: 0, count: frames * channels) }
            for c in 0..<min(channels, list.count) {
                guard let data = list[c].mData else { continue }
                let src = data.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { interleaved[i * channels + c] = src[i] }
            }
            interleaved.withUnsafeBytes { emit($0.baseAddress!, $0.count) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { fail("se detuvo: \(error.localizedDescription)", 3) }
}

let output = AudioOut()
var capture: SCStream?

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { fail("no hay pantalla para capturar", 2) }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // ScreenCaptureKit always captures video too: make it as small and slow as possible (it is ignored).
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "rc-audio"))
        try await stream.startCapture()
        capture = stream
    } catch {
        // The usual cause: Premiere has no Screen Recording permission (Settings > Privacy & Security).
        fail("no se pudo capturar el audio (\(error.localizedDescription)). Revisá el permiso de Grabación de pantalla de Premiere.", 2)
    }
}

// The panel can close without closing our stdout (crash): stop when the parent is gone.
let parent = getppid()
_ = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in if getppid() != parent { exit(0) } }
signal(SIGPIPE, SIG_IGN)
RunLoop.main.run()
