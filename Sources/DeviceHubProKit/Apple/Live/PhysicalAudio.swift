import AVFoundation
import CoreMedia
import Foundation

// The audio of a USB-connected iPhone's live view ("Landed in
// "): the muxed capture device that carries the screen also
// carries the phone's audio, and the same `AVCaptureSession` delivers it
// through an `AVCaptureAudioDataOutput`. Nothing here is private API and
// nothing here sends anything to the phone.

/// One chunk of the phone's audio as the capture delivered it: linear PCM in
/// the device's own format (a different rate, channel count or sample type
/// than the Mac's output is the player's to adapt). The buffer is written
/// once, by the capture, before it is handed on, and only read afterwards.
public struct PhysicalAudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// The linear PCM of `sampleBuffer` as an `AVAudioPCMBuffer` of the
    /// sample buffer's own format. Nil for a buffer that is not ready, is
    /// empty, or does not hold linear PCM (the capture delivers linear PCM
    /// unless asked otherwise).
    public init?(sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              stream.pointee.mFormatID == kAudioFormatLinearPCM
        else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        self.buffer = buffer
    }
}

/// Where a live session sends the phone's audio: the app's player. Every
/// method may be called from any thread; `play` runs on the capture's audio
/// queue and must not block it.
public protocol PhysicalAudioSink: AnyObject, Sendable {
    /// Plays `chunk` (dropped when the sink is not playing).
    func play(_ chunk: PhysicalAudioChunk)
    /// Turns playing on or off (the audio policy and the mute toggle). Off
    /// drops what is queued and lets go of the output device; the chunks that
    /// arrive while it is off are dropped, not queued.
    func setPlaying(_ playing: Bool)
    /// The session stopped: drops what is queued and lets go of the output
    /// device. The sink can play again (a session that restarts).
    func stop()
}
