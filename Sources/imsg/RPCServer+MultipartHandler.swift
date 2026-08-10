import Foundation
import IMsgCore

extension RPCServer {
  func handleSendMultipart(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      ["parts", "effect_id", "effectId", "effect", "subject"]
    )
    let params = try RPCParameters(
      params, method: "send.multipart", supportedKeys: supportedKeys)
    guard let rawParts = try params.objectArray("parts") else {
      throw RPCError.invalidParams("parts is required")
    }
    guard !rawParts.isEmpty, rawParts.count <= 20 else {
      throw RPCError.invalidParams("parts must contain between 1 and 20 text parts")
    }

    var parts: [[String: Any]] = []
    parts.reserveCapacity(rawParts.count)
    for (index, rawPart) in rawParts.enumerated() {
      if let key = rawPart.keys.sorted().first(where: {
        ["file", "attachment", "mention", "mentions"].contains($0)
      }) {
        throw RPCError.invalidParams("\(key) parts are not supported")
      }
      let part = try RPCParameters(
        rawPart,
        method: "send.multipart parts[\(index)]",
        supportedKeys: ["text", "text_formatting", "textFormatting"]
      )
      guard let text = try part.string("text"), !text.isEmpty else {
        throw RPCError.invalidParams("parts[\(index)].text must be a non-empty string")
      }
      var bridgePart: [String: Any] = ["text": text]
      if let formatting = try part.objectArray(
        "text_formatting", aliases: ["textFormatting"])
      {
        bridgePart["textFormatting"] = formatting
      }
      parts.append(bridgePart)
    }

    let effect = try params.string("effect_id", aliases: ["effectId", "effect"])
    let subject = try params.string("subject")
    let chatGUID = try await resolveChatGUIDParam(params)
    var bridgeParams: [String: Any] = ["chatGuid": chatGUID, "parts": parts]
    if let effect, !effect.isEmpty {
      bridgeParams["effectId"] = ExpressiveSendEffect.expand(effect)
    }
    if let subject, !subject.isEmpty {
      bridgeParams["subject"] = subject
    }

    let verification = try await bridgeSendVerificationBaseline()
    let data = try await invokeBridge(action: .sendMultipart, params: bridgeParams)
    var result = try await verifiedBridgeSendResponse(
      data,
      params: params,
      chatGUID: chatGUID,
      action: .sendMultipart,
      database: verification.database,
      baselineRowID: verification.rowID
    )
    result["ok"] = true
    result["parts_count"] = parts.count
    respond(id: id, result: result)
  }
}
