import Foundation
import IMsgCore
import Testing

@testable import imsg

@Test
func rpcSendStickerAcceptsBridgeGuidForAnyStoredGroupTarget() async throws {
  let store = try CommandTestDatabase.makeStoreForRPCWithStickerTarget(useAnyGroupGUID: true)
  let output = TestRPCOutput()
  var capturedParams: [String: Any] = [:]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    invokeBridge: { _, params in
      capturedParams = params
      return ["messageGuid": "sticker-guid", "transferGuid": "transfer-guid"]
    },
    stageSticker: { _ in
      PreparedStickerAsset(
        stagedPath: "/tmp/staged-sticker.png",
        sha256: String(repeating: "e", count: 64),
        pixelWidth: 64,
        pixelHeight: 64,
        uti: "public.png",
        byteCount: 100,
        accessibilityLabel: "Sticker"
      )
    }
  )

  let request =
    #"{"jsonrpc":"2.0","id":"any-group","method":"send.sticker","params":{"#
    + #""chat_guid":"iMessage;+;chat123","file":"~/Desktop/sticker.png","attach_to":"parent-guid"}}"#
  await server.handleLineForTesting(request)

  #expect(output.errors.isEmpty)
  #expect(capturedParams["chatGuid"] as? String == "any;+;chat123")
  #expect(capturedParams["selectedMessageGuid"] as? String == "parent-guid")
}
