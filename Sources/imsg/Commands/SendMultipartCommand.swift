import Commander
import Foundation
import IMsgCore

enum SendMultipartCommand {
  static let spec = CommandSpec(
    name: "send-multipart",
    abstract: "Send a multi-part message",
    discussion: """
      Pass --parts as a JSON array (e.g., '[{"text":"hi"},{"text":"there"}]')
      or via --parts-file pointing at a .json file. v1 supports text-only
      parts; mention/file parts are a future enhancement.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "parts", names: [.long("parts")], help: "JSON array of parts"),
          .make(
            label: "partsFile", names: [.long("parts-file")],
            help: "path to JSON file containing parts array"),
          .make(label: "effect", names: [.long("effect")], help: "expressive send id"),
          .make(label: "subject", names: [.long("subject")], help: "subject line"),
        ]
      )
    ),
    usageExamples: [
      "imsg send-multipart --chat 'iMessage;+;chat0000' --parts '[{\"text\":\"hi\"},{\"text\":\"world\"}]'"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    let partsRaw: String
    if let inline = values.option("parts"), !inline.isEmpty {
      partsRaw = inline
    } else if let path = values.option("partsFile"), !path.isEmpty {
      partsRaw = try String(contentsOfFile: path, encoding: .utf8)
    } else {
      throw ParsedValuesError.missingOption("parts")
    }
    guard
      let data = partsRaw.data(using: .utf8),
      let parts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      throw ParsedValuesError.invalidOption("parts")
    }
    var params: [String: Any] = ["chatGuid": chat, "parts": parts]
    if let effect = values.option("effect"), !effect.isEmpty {
      params["effectId"] = ExpressiveSendEffect.expand(effect)
    }
    if let subject = values.option("subject"), !subject.isEmpty { params["subject"] = subject }

    _ = try await BridgeOutput.invokeAndEmit(
      action: .sendMultipart, params: params, runtime: runtime
    ) { data in
      let guid = (data["messageGuid"] as? String) ?? ""
      let count = (data["parts_count"] as? Int) ?? 0
      return "send-multipart: \(count) parts queued (guid=\(guid))"
    }
  }
}

// MARK: - react (BB-style; complements existing AS-backed `react`)
