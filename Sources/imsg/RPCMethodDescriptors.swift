import Foundation

let kRPCProtocolVersion = 1

enum RPCRequestLane: Sendable, Equatable {
  case mutation
  case read
  case control
}

enum RPCDatabaseRequirement: Sendable, Equatable {
  case ready
  case scheduledMessages
  case balloonPayloads
  case reactions
}

struct RPCBridgeRequirement: Sendable, Equatable {
  let requiresRegistry: Bool
  let allSelectors: [String]
  let anySelectors: [String]

  static let none = RPCBridgeRequirement(
    requiresRegistry: false, allSelectors: [], anySelectors: [])

  static func selector(
    _ name: String,
    requiresRegistry: Bool = true
  ) -> RPCBridgeRequirement {
    RPCBridgeRequirement(
      requiresRegistry: requiresRegistry, allSelectors: [name], anySelectors: [])
  }

  static func anySelector(_ names: String...) -> RPCBridgeRequirement {
    RPCBridgeRequirement(requiresRegistry: true, allSelectors: [], anySelectors: names)
  }
}

struct RPCMethodDescriptor: Sendable, Equatable {
  let names: [String]
  let lane: RPCRequestLane
  let database: [RPCDatabaseRequirement]
  let bridge: RPCBridgeRequirement
  let macOSOnly: Bool

  var isCompiledForCurrentPlatform: Bool {
    #if os(macOS)
      true
    #else
      !macOSOnly
    #endif
  }

  init(
    _ names: String...,
    lane: RPCRequestLane,
    database: [RPCDatabaseRequirement] = [],
    bridge: RPCBridgeRequirement = .none,
    macOSOnly: Bool = false
  ) {
    self.names = names
    self.lane = lane
    self.database = database
    self.bridge = bridge
    self.macOSOnly = macOSOnly
  }

  func isUsable(database snapshot: RPCDatabaseSnapshot, bridge status: RPCBridgeSnapshot) -> Bool {
    guard isCompiledForCurrentPlatform else { return false }

    for requirement in database {
      switch requirement {
      case .ready:
        guard snapshot.resources != nil else { return false }
      case .scheduledMessages:
        guard snapshot.capabilities?.scheduledMessages == true else { return false }
      case .balloonPayloads:
        guard snapshot.capabilities?.balloonPayloads == true else { return false }
      case .reactions:
        guard snapshot.capabilities?.reactions == true else { return false }
      }
    }
    return status.supports(bridge)
  }
}

let rpcMethodDescriptors: [RPCMethodDescriptor] = [
  RPCMethodDescriptor("initialize", lane: .control),
  RPCMethodDescriptor("status", lane: .read),
  RPCMethodDescriptor("watch.unsubscribe", lane: .control),
  RPCMethodDescriptor("chats.list", lane: .read, database: [.ready]),
  RPCMethodDescriptor("messages.stats", lane: .read, database: [.ready]),
  RPCMethodDescriptor("messages.history", lane: .read, database: [.ready]),
  RPCMethodDescriptor("messages.after", lane: .read, database: [.ready]),
  RPCMethodDescriptor("messages.scheduled", lane: .read, database: [.scheduledMessages]),
  RPCMethodDescriptor("watch.subscribe", lane: .control, database: [.ready]),
  RPCMethodDescriptor("message.send_status", lane: .read, database: [.ready]),
  RPCMethodDescriptor("send", lane: .mutation, macOSOnly: true),
  RPCMethodDescriptor(
    "chats.create", lane: .mutation, bridge: .selector("createChat"), macOSOnly: true),
  RPCMethodDescriptor(
    "chats.delete", lane: .mutation, bridge: .anySelector("deleteChat", "removeChat"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "chats.markUnread", lane: .mutation, bridge: .selector("markChatUnread"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "send.rich", lane: .mutation, bridge: .selector("sendMessage"), macOSOnly: true),
  RPCMethodDescriptor(
    "send.attachment", lane: .mutation, bridge: .selector("sendAttachment"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "send.sticker", lane: .mutation, database: [.ready], bridge: .selector("stickerSend"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "poll.send", "messages.poll.send", lane: .mutation,
    bridge: .selector("pollPayloadMessage"), macOSOnly: true),
  RPCMethodDescriptor(
    "poll.vote", "messages.poll.vote", lane: .mutation,
    database: [.ready, .balloonPayloads], bridge: .selector("pollVoteMessage"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "poll.unvote", "polls.unvote", "messages.poll.unvote", lane: .mutation,
    database: [.ready, .balloonPayloads, .reactions],
    bridge: .selector("pollVoteMessage"), macOSOnly: true),
  RPCMethodDescriptor(
    "tapback", lane: .mutation, bridge: .selector("sendReaction"), macOSOnly: true),
  RPCMethodDescriptor(
    "typing", lane: .mutation, bridge: .selector("typing"), macOSOnly: true),
  RPCMethodDescriptor("read", lane: .mutation, bridge: .selector("read"), macOSOnly: true),
  RPCMethodDescriptor(
    "message.edit", lane: .mutation,
    bridge: .anySelector("editMessageItemTranslation", "editMessageItem", "editMessage"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "message.unsend", lane: .mutation, bridge: .selector("retractMessagePart"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "message.delete", lane: .mutation, bridge: .selector("deleteMessage"), macOSOnly: true),
  RPCMethodDescriptor(
    "message.notifyAnyways", lane: .mutation, bridge: .selector("notifyAnyways"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "group.rename", lane: .mutation, bridge: .selector("setDisplayName"), macOSOnly: true),
  RPCMethodDescriptor(
    "group.setIcon", lane: .mutation, bridge: .selector("updateGroupPhoto"), macOSOnly: true),
  RPCMethodDescriptor(
    "group.addParticipant", lane: .mutation, bridge: .selector("addParticipant"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "group.removeParticipant", lane: .mutation, bridge: .selector("removeParticipant"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "group.leave", lane: .mutation, bridge: .selector("leaveChat"), macOSOnly: true),
  RPCMethodDescriptor(
    "contacts.shouldShareContact", lane: .read, bridge: .selector("namePhotoShouldOffer"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "contacts.shareContactCard", lane: .mutation, bridge: .selector("namePhotoShare"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "handles.check", lane: .read,
    bridge: .selector("checkIMessageAvailability", requiresRegistry: false),
    macOSOnly: true),
]

let kSupportedRPCMethods: [String] =
  rpcMethodDescriptors
  .filter(\.isCompiledForCurrentPlatform)
  .flatMap(\.names)

private let rpcMethodByName: [String: RPCMethodDescriptor] = {
  var result: [String: RPCMethodDescriptor] = [:]
  for descriptor in rpcMethodDescriptors {
    for name in descriptor.names { result[name] = descriptor }
  }
  return result
}()

func rpcRequestLane(for method: String) -> RPCRequestLane {
  guard let descriptor = rpcMethodByName[method], descriptor.isCompiledForCurrentPlatform else {
    return .control
  }
  return descriptor.lane
}

func rpcUsableMethods(
  database: RPCDatabaseSnapshot,
  bridge: RPCBridgeSnapshot
) -> [String] {
  rpcMethodDescriptors
    .filter { $0.isUsable(database: database, bridge: bridge) }
    .flatMap(\.names)
}
