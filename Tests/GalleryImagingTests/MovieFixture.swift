import Foundation
import AVFoundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Writes a real one-second H.264 clip with a creation date in the movie header, so the video half of pass
/// B is tested against a container AVFoundation will actually open rather than against a stub that only
/// proves the failure path.
enum MovieFixture {
    enum Failure: Error {
        case noWriter(String)
        case noPixelBuffer

        var localizedDescription: String {
            switch self {
            case .noWriter(let reason): "could not write a test clip: \(reason)"
            case .noPixelBuffer: "could not allocate a pixel buffer to encode"
            }
        }
    }

    /// The clip is 320x240 with an identity transform, which is the case a test should be able to rely on:
    /// a phone-rotated clip would make every expected number here depend on how the encoder chose to store
    /// the rotation.
    static func write(into directory: URL, named name: String = "clip.mov",
                      seconds: Double = 1, frameRate: Int = 30, width: Int = 320, height: Int = 240,
                      creationDate: Date? = nil) async throws -> URL {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw Failure.noWriter("h264 \(width)x\(height) refused") }
        writer.add(input)
        if let creationDate {
            let item = AVMutableMetadataItem()
            item.key = AVMetadataKey.commonKeyCreationDate as (any NSCopying & NSObjectProtocol)
            item.keySpace = .common
            item.value = creationDate as NSDate
            writer.metadata = [item]
        }
        writer.startWriting()
        if let error = writer.error { throw Failure.noWriter(error.localizedDescription) }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(frameRate))
        for frame in 0..<max(1, frames) {
            guard let buffer = pixelBuffer(width: width, height: height) else {
                throw Failure.noPixelBuffer
            }
            // The adaptor drops frames faster than a test can wait for them, and a clip that came out
            // shorter than asked for would make the duration assertion wrong rather than red.
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            _ = adaptor.append(buffer,
                               withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                            timescale: CMTimeScale(frameRate)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw Failure.noWriter(error.localizedDescription) }
        return url
    }

    private static func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         nil, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }
}
