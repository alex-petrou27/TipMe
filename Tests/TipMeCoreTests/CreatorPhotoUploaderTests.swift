import XCTest
@testable import TipMeCore

/// `multipartBody` is what the registry's `python-multipart` parser has to
/// make sense of on the other end — a malformed boundary or missing blank
/// line between headers and body fails silently as an empty upload rather
/// than a clear error, so its shape is worth pinning down explicitly.
final class CreatorPhotoUploaderTests: XCTestCase {

    func testMultipartBodyHasTheExpectedShape() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let body = CreatorPhotoUploader.multipartBody(boundary: "test-boundary",
                                                       imageData: imageData,
                                                       format: .jpeg)
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("--test-boundary\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n"))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n--test-boundary--\r\n"))
        XCTAssertTrue(body.range(of: imageData) != nil)
    }

    func testMultipartBodyNamesThePNGExtension() throws {
        let body = CreatorPhotoUploader.multipartBody(boundary: "b", imageData: Data(), format: .png)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"photo.png\""))
        XCTAssertTrue(text.contains("Content-Type: image/png"))
    }
}
