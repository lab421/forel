import Foundation
import AVFoundation
import CoreVideo
import Testing
@testable import ForelCore

@Suite struct VideoDateTakenTests {
    @Test func readsEmbeddedVideoCreationDateAndNeverFallsBack() async throws {
        let dir = TempDir(); let url = URL(fileURLWithPath: dir.path).appendingPathComponent("clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let metadata = AVMutableMetadataItem(); metadata.identifier = .commonIdentifierCreationDate
        metadata.value = "2020-05-01T12:34:56+02:00" as NSString
        metadata.extendedLanguageTag = "und"; writer.metadata = [metadata]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
        #expect(writer.canAdd(input)); writer.add(input)
        #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        #expect(adaptor.append(try #require(buffer), withPresentationTime: .zero))
        input.markAsFinished(); await writer.finishWriting()
        #expect(writer.status == .completed)
        let expected = try #require(ISO8601DateFormatter().date(from: "2020-05-01T12:34:56+02:00"))
        let extracted = try #require(VideoDateTaken.read(path: url.path))
        #expect(abs(extracted.timeIntervalSince(expected)) < 1)
        let corrupt = dir.file("invalid.mov", contents: "not a video")
        #expect(VideoDateTaken.read(path: corrupt) == nil)
        #expect(throws: ActionError.self) { try HazelPattern.dateValue("hazelbuiltin:dateTaken", path: corrupt) }
    }
}
