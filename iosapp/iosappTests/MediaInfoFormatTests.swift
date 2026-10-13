import Testing
@testable import iosapp

// Uploads store a UTI in the field details label "Format". The row
// has to show a file type a person recognizes, including for libraries
// that were uploaded before this display change.
struct MediaInfoFormatTests {
    @Test func displayFormatUsesFileExtension() {
        #expect(MediaInfoContent.displayFormat(for: "public.heic") == "HEIC")
        #expect(MediaInfoContent.displayFormat(for: "image/jpeg") == "JPEG")
        #expect(MediaInfoContent.displayFormat(for: "com.apple.quicktime-movie") == "MOV")
        #expect(MediaInfoContent.displayFormat(for: "not-a-type") == "not-a-type")
    }
}
