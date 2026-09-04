import Foundation
import Testing

@testable import IMsgCore

// Messages stores the legacy NSArchiver format; use its writer as the fixture oracle.
func archivedAttributedBody(_ text: String) -> Data {
  NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
}

@Test(arguments: [0, 5, 32, 64, 126, 127, 128, 140, 160, 255, 256, 300, 8192, 8448, 32768])
func typedStreamDecodesNativeLengthFrames(length: Int) {
  let text = String(repeating: "a", count: length)
  let decoded = TypedStreamParser.parseAttributedBody(archivedAttributedBody(text))
  let matches = decoded == text
  #expect(matches, "Native archive with \(length) body bytes must round-trip")
}

@Test(arguments: ["left ↄ right", "🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉", "\n\nhello", "left\u{1}+right"])
func typedStreamPreservesNativeText(text: String) {
  #expect(TypedStreamParser.parseAttributedBody(archivedAttributedBody(text)) == text)
}

@Test
func typedStreamDoesNotReadAttributeValuesAsMessageText() {
  let attributed = NSAttributedString(
    string: "hello",
    attributes: [NSAttributedString.Key("fixture-key"): String(repeating: "x", count: 100)]
  )
  let data = NSArchiver.archivedData(withRootObject: attributed)
  #expect(TypedStreamParser.parseAttributedBody(data) == "hello")
}

@Test
func typedStreamRejectsTruncatedAndInvalidLengthFrames() {
  let header = [UInt8(4), 11] + Array("streamtyped".utf8) + [0x81, 0xe8, 0x03, 0x01, 0x2b]
  for payload: [UInt8] in [
    [], [0x81], [0x81, 0x01], [0x82, 1, 0, 0], [0x82, 0xff, 0xff, 0xff, 0xff],
    [0x85], [5, 0x61, 0x62], [1, 0xff, 0x86],
  ] {
    #expect(TypedStreamParser.parseAttributedBody(Data(header + payload)).isEmpty)
  }
}

@Test
func typedStreamReadsBigEndianLengths() {
  let text = String(repeating: "b", count: 300)
  let bytes =
    [UInt8(4), 11] + Array("typedstream".utf8)
    + [0x81, 0x03, 0xe8, 0x01, 0x2b, 0x81, 0x01, 0x2c] + Array(text.utf8) + [0x86]
  let matches = TypedStreamParser.parseAttributedBody(Data(bytes)) == text
  #expect(matches)
}

@Test
func typedStreamParserTrimsRawControlPrefix() {
  let data = Data([0x00, 0x0a] + Array("hello".utf8))
  #expect(TypedStreamParser.parseAttributedBody(data) == "hello")
}

@Test
func typedStreamParserDecodesUTF16LittleEndianBOM() throws {
  let text = "\nhello 🌤️"
  var data = Data([0xff, 0xfe])
  data.append(try #require(text.data(using: .utf16LittleEndian)))
  #expect(TypedStreamParser.parseAttributedBody(data) == text)
  #expect(TypedStreamParser.parseAttributedBody(Data([0xff, 0xfe, 0x61])).isEmpty)
}
