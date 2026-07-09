import Commander
import Foundation
import IMsgCore

enum StatsCommand {
  static let spec = CommandSpec(
    name: "stats",
    abstract: "Show aggregate message and media statistics",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "Limit stats to a chat rowid"),
          .make(
            label: "timeZone", names: [.long("time-zone")],
            help: "IANA time zone for date buckets (defaults to local)"
          ),
        ],
        flags: [
          .make(label: "media", names: [.long("media")], help: "include attachment statistics")
        ]
      )
    ),
    usageExamples: [
      "imsg stats",
      "imsg stats --chat-id 42 --time-zone Europe/Vienna --media --json",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let chatID: Int64?
    if let rawChatID = values.option("chatID") {
      guard let parsed = Int64(rawChatID) else {
        throw ParsedValuesError.invalidOption("chat-id")
      }
      chatID = parsed
    } else {
      chatID = nil
    }
    let includeMedia = values.flag("media")
    let store = try MessageStore(path: dbPath)
    let stats = try store.messageStats(
      chatID: chatID,
      includeMedia: includeMedia,
      timeZoneIdentifier: values.option("timeZone")
    )

    if runtime.jsonOutput {
      try JSONLines.print(stats)
      return
    }

    printSummary(stats)
  }

  private static func printSummary(_ stats: MessageStats) {
    StdoutWriter.writeLine(
      "Messages: \(stats.totalMessages) (\(stats.sentMessages) sent, \(stats.receivedMessages) received)"
    )
    StdoutWriter.writeLine("Time zone: \(stats.timeZone)")

    if !stats.chats.isEmpty {
      StdoutWriter.writeLine("By chat:")
      for chat in stats.chats {
        StdoutWriter.writeLine(
          "  \(chat.chatID) \(chat.name): \(chat.messageCount) (\(chat.service))")
      }
    }

    if !stats.senders.isEmpty {
      StdoutWriter.writeLine("By sender:")
      for sender in stats.senders {
        StdoutWriter.writeLine("  \(sender.handle): \(sender.messageCount)")
      }
    }

    if !stats.services.isEmpty {
      StdoutWriter.writeLine("By service:")
      for service in stats.services {
        StdoutWriter.writeLine("  \(service.service): \(service.messageCount)")
      }
    }

    if !stats.dates.isEmpty {
      StdoutWriter.writeLine("By date:")
      for date in stats.dates {
        StdoutWriter.writeLine("  \(date.date): \(date.messageCount)")
      }
    }

    guard let media = stats.media else { return }
    StdoutWriter.writeLine(
      "Media: \(media.totalAttachments) attachments, \(media.totalBytes) bytes")
    if !media.types.isEmpty {
      StdoutWriter.writeLine("By media type:")
      for type in media.types {
        StdoutWriter.writeLine(
          "  \(type.uti) \(type.mimeType): \(type.attachmentCount), \(type.totalBytes) bytes")
      }
    }
    if !media.chats.isEmpty {
      StdoutWriter.writeLine("Media by chat:")
      for chat in media.chats {
        StdoutWriter.writeLine(
          "  \(chat.chatID) \(chat.name): \(chat.attachmentCount), \(chat.totalBytes) bytes")
      }
    }
  }
}
