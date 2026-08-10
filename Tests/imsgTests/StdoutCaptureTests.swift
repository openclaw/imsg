import Foundation
import Testing

@Test
func stdoutCaptureDrainsMoreThanPipeCapacity() async {
  let payloadSize = 1024 * 1024
  let payload = Data(repeating: 0x78, count: payloadSize)

  let captured = await StdoutCapture.capture {
    FileHandle.standardOutput.write(payload)
  }

  #expect(captured.output.utf8.count == payloadSize)
  #expect(captured.output.utf8.allSatisfy { $0 == 0x78 })
}
