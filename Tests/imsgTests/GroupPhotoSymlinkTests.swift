import Commander
import Foundation
import IMsgCore
import Testing

@testable import imsg

@Test
func injectedHelperRefusesSymlinkGroupPhotoPaths() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helper = repoRoot.appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = try String(contentsOf: helper, encoding: .utf8)
  let start = try #require(source.range(of: "static NSDictionary *handleUpdateGroupPhoto"))
  let searchFrom =
    source.index(start.lowerBound, offsetBy: 80, limitedBy: source.endIndex) ?? source.endIndex
  let end =
    source.range(of: "\nstatic ", range: searchFrom..<source.endIndex)?.lowerBound
    ?? source.endIndex
  let photoBody = String(source[start.lowerBound..<end])

  let clearPhoto = try #require(photoBody.range(of: "filePath.length == 0"))
  let symlinkCheck = try #require(photoBody.range(of: "pathHasSymlinkComponent(filePath)"))
  let prepare = try #require(photoBody.range(of: "prepareOutgoingTransfer("))
  #expect(clearPhoto.lowerBound < symlinkCheck.lowerBound)
  #expect(symlinkCheck.lowerBound < prepare.lowerBound)
  #expect(photoBody.contains("path traverses a symlink"))
}

@Test
func chatPhotoAndGroupSetIconStageAttachmentsBeforeBridge() throws {
  let testFile = URL(fileURLWithPath: #filePath)
  let repoRoot =
    testFile
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let cli = try String(
    contentsOf: repoRoot.appendingPathComponent("Sources/imsg/Commands/BridgeChatCommands.swift"),
    encoding: .utf8)
  let rpc = try String(
    contentsOf: repoRoot.appendingPathComponent("Sources/imsg/RPCServer+ChatHandlers.swift"),
    encoding: .utf8)

  let photoStart = try #require(cli.range(of: "enum ChatPhotoCommand"))
  let photoEnd = try #require(cli.range(of: "enum ChatAddMemberCommand"))
  let photoSource = String(cli[photoStart.lowerBound..<photoEnd.lowerBound])
  let stage = try #require(photoSource.range(of: "stageAttachment"))
  let invoke = try #require(photoSource.range(of: "updateGroupPhoto"))
  #expect(stage.lowerBound < invoke.lowerBound)
  #expect(photoSource.contains("stageAttachmentForMessagesApp"))

  let iconStart = try #require(rpc.range(of: "func handleGroupSetIcon"))
  let iconEnd = try #require(rpc.range(of: "func handleGroupAddParticipant"))
  let iconBody = String(rpc[iconStart.lowerBound..<iconEnd.lowerBound])
  let rpcStage = try #require(iconBody.range(of: "stageAttachment"))
  let rpcInvoke = try #require(iconBody.range(of: "updateGroupPhoto"))
  #expect(rpcStage.lowerBound < rpcInvoke.lowerBound)
}

@Test
func chatPhotoStagesFileBeforeUpdateGroupPhoto() async throws {
  let values = ParsedValues(
    positional: [],
    options: [
      "chat": ["iMessage;+;chat0000"],
      "file": ["~/Downloads/g.jpg"],
    ],
    flags: []
  )
  var staged: [String] = []
  var capturedAction: BridgeAction?
  var capturedParams: [String: Any] = [:]

  let (output, _) = try await StdoutCapture.capture {
    try await ChatPhotoCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { action, params in
        capturedAction = action
        capturedParams = params
        return [:]
      },
      stageAttachment: { path in
        staged.append(path)
        return "/staged/g.jpg"
      }
    )
  }

  #expect(capturedAction == .updateGroupPhoto)
  #expect(staged == [("~/Downloads/g.jpg" as NSString).expandingTildeInPath])
  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat0000")
  #expect(capturedParams["filePath"] as? String == "/staged/g.jpg")
  #expect(output.contains("chat-photo: updated"))
}

@Test
func chatPhotoClearOmitsFilePathAndSkipsStaging() async throws {
  let values = ParsedValues(
    positional: [],
    options: ["chat": ["iMessage;+;chat0000"]],
    flags: []
  )
  var staged = false
  var capturedParams: [String: Any] = [:]

  _ = try await StdoutCapture.capture {
    try await ChatPhotoCommand.run(
      values: values,
      runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { _, params in
        capturedParams = params
        return [:]
      },
      stageAttachment: { _ in
        staged = true
        return "/staged/unused.jpg"
      }
    )
  }

  #expect(staged == false)
  #expect(capturedParams["chatGuid"] as? String == "iMessage;+;chat0000")
  #expect(capturedParams["filePath"] == nil)
}
