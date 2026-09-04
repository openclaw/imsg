import Foundation

enum TypedStreamParser {
  static func parseAttributedBody(_ data: Data) -> String {
    guard !data.isEmpty else { return "" }
    let bytes = [UInt8](data)
    if bytes.starts(with: [0xff, 0xfe]) {
      return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
    }
    guard bytes.starts(with: [4, 11]) else {
      return String(decoding: bytes, as: UTF8.self).trimmingLeadingControlCharacters()
    }
    guard bytes.count >= 13 else { return "" }
    let signature = bytes[2..<13]
    let littleEndian = signature.elementsEqual("streamtyped".utf8)
    guard littleEndian || signature.elementsEqual("typedstream".utf8) else { return "" }

    var index = 13
    while index + 1 < bytes.count {
      if bytes[index] == 0x01, bytes[index + 1] == 0x2b {
        // The first NSString is the message body. Length framing preserves embedded
        // object-marker bytes in UTF-8 and avoids reading later attribute values.
        return decodeString(bytes, from: index + 2, littleEndian: littleEndian) ?? ""
      }
      index += 1
    }
    return ""
  }

  private static func decodeString(_ bytes: [UInt8], from index: Int, littleEndian: Bool)
    -> String?
  {
    guard index < bytes.count else { return nil }
    let head = bytes[index]
    var bodyStart = index + 1
    var length = 0
    if head == 0x81 || head == 0x82 {
      // Typedstream integers use two or four bytes in the archive's byte order.
      let width = head == 0x81 ? 2 : 4
      guard width <= bytes.count - bodyStart else { return nil }
      for offset in 0..<width {
        let shift = (littleEndian ? offset : width - 1 - offset) * 8
        length |= Int(bytes[bodyStart + offset]) << shift
      }
      bodyStart += width
    } else {
      guard !(0x80...0x91).contains(head) else { return nil }
      length = Int(head)
    }
    guard length <= bytes.count - bodyStart else { return nil }
    return String(bytes: bytes[bodyStart..<(bodyStart + length)], encoding: .utf8)
  }
}

extension String {
  fileprivate func trimmingLeadingControlCharacters() -> String {
    var scalars = unicodeScalars
    while let first = scalars.first, CharacterSet.controlCharacters.contains(first) {
      scalars.removeFirst()
    }
    return String(String.UnicodeScalarView(scalars))
  }
}
