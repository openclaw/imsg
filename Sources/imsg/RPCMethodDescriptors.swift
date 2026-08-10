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

enum RPCDispatchRoute: Sendable, Equatable {
  case initialize, status, chatsList, messagesStats, messagesHistory, messagesSearch
  case messagesAfter, watchSubscribe, watchUnsubscribe, send, sendRich, sendAttachment
  case sendMultipart, sendSticker, messagesScheduled, pollSend, pollVote, pollUnvote
  case tapback, typing, read, messageEdit, messageUnsend, messageDelete
  case messageNotifyAnyways, messageSendStatus, chatsCreate, chatsDelete, chatsMarkUnread
  case groupRename, groupSetIcon, groupAddParticipant, groupRemoveParticipant, groupLeave
  case contactsShouldShare, contactsShare, handlesCheck
}

struct RPCMethodDescriptor: Sendable, Equatable {
  let names: [String]
  let route: RPCDispatchRoute
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
    route: RPCDispatchRoute,
    lane: RPCRequestLane,
    database: [RPCDatabaseRequirement] = [],
    bridge: RPCBridgeRequirement = .none,
    macOSOnly: Bool = false
  ) {
    self.names = names
    self.route = route
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
  RPCMethodDescriptor("initialize", route: .initialize, lane: .control),
  RPCMethodDescriptor("status", route: .status, lane: .read),
  RPCMethodDescriptor("watch.unsubscribe", route: .watchUnsubscribe, lane: .control),
  RPCMethodDescriptor("chats.list", route: .chatsList, lane: .read, database: [.ready]),
  RPCMethodDescriptor(
    "messages.stats", route: .messagesStats, lane: .read, database: [.ready]),
  RPCMethodDescriptor(
    "messages.history", route: .messagesHistory, lane: .read, database: [.ready]),
  RPCMethodDescriptor(
    "messages.search", route: .messagesSearch, lane: .read, database: [.ready]),
  RPCMethodDescriptor(
    "messages.after", route: .messagesAfter, lane: .read, database: [.ready]),
  RPCMethodDescriptor(
    "messages.scheduled", route: .messagesScheduled, lane: .read,
    database: [.scheduledMessages]),
  RPCMethodDescriptor(
    "watch.subscribe", route: .watchSubscribe, lane: .control, database: [.ready]),
  RPCMethodDescriptor(
    "message.send_status", route: .messageSendStatus, lane: .read, database: [.ready]),
  RPCMethodDescriptor("send", route: .send, lane: .mutation, macOSOnly: true),
  RPCMethodDescriptor(
    "chats.create", route: .chatsCreate, lane: .mutation, bridge: .selector("createChat"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "chats.delete", route: .chatsDelete, lane: .mutation,
    bridge: .anySelector("deleteChat", "removeChat"), macOSOnly: true),
  RPCMethodDescriptor(
    "chats.markUnread", route: .chatsMarkUnread, lane: .mutation,
    bridge: .selector("markChatUnread"), macOSOnly: true),
  RPCMethodDescriptor(
    "send.rich", route: .sendRich, lane: .mutation, bridge: .selector("sendMessage"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "send.attachment", route: .sendAttachment, lane: .mutation,
    bridge: .selector("sendAttachment"), macOSOnly: true),
  RPCMethodDescriptor(
    "send.multipart", route: .sendMultipart, lane: .mutation,
    database: [.ready], bridge: .selector("sendMultipart"), macOSOnly: true),
  RPCMethodDescriptor(
    "send.sticker", route: .sendSticker, lane: .mutation, database: [.ready],
    bridge: .selector("stickerSend"), macOSOnly: true),
  RPCMethodDescriptor(
    "poll.send", "messages.poll.send", route: .pollSend, lane: .mutation,
    bridge: .selector("pollPayloadMessage"), macOSOnly: true),
  RPCMethodDescriptor(
    "poll.vote", "messages.poll.vote", route: .pollVote, lane: .mutation,
    database: [.ready, .balloonPayloads], bridge: .selector("pollVoteMessage"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "poll.unvote", "polls.unvote", "messages.poll.unvote", route: .pollUnvote,
    lane: .mutation,
    database: [.ready, .balloonPayloads, .reactions],
    bridge: .selector("pollVoteMessage"), macOSOnly: true),
  RPCMethodDescriptor(
    "tapback", route: .tapback, lane: .mutation, bridge: .selector("sendReaction"),
    macOSOnly: true),
  RPCMethodDescriptor("typing", route: .typing, lane: .mutation, macOSOnly: true),
  RPCMethodDescriptor("read", route: .read, lane: .mutation, macOSOnly: true),
  RPCMethodDescriptor(
    "message.edit", route: .messageEdit, lane: .mutation,
    bridge: .anySelector("editMessageItemTranslation", "editMessageItem", "editMessage"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "message.unsend", route: .messageUnsend, lane: .mutation,
    bridge: .selector("retractMessagePart"), macOSOnly: true),
  RPCMethodDescriptor(
    "message.delete", route: .messageDelete, lane: .mutation,
    bridge: .selector("deleteMessage"), macOSOnly: true),
  RPCMethodDescriptor(
    "message.notifyAnyways", route: .messageNotifyAnyways, lane: .mutation,
    bridge: .selector("notifyAnyways"), macOSOnly: true),
  RPCMethodDescriptor(
    "group.rename", route: .groupRename, lane: .mutation,
    bridge: .selector("setDisplayName"), macOSOnly: true),
  RPCMethodDescriptor(
    "group.setIcon", route: .groupSetIcon, lane: .mutation,
    bridge: .selector("updateGroupPhoto"), macOSOnly: true),
  RPCMethodDescriptor(
    "group.addParticipant", route: .groupAddParticipant, lane: .mutation,
    bridge: .selector("addParticipant"), macOSOnly: true),
  RPCMethodDescriptor(
    "group.removeParticipant", route: .groupRemoveParticipant, lane: .mutation,
    bridge: .selector("removeParticipant"), macOSOnly: true),
  RPCMethodDescriptor(
    "group.leave", route: .groupLeave, lane: .mutation, bridge: .selector("leaveChat"),
    macOSOnly: true),
  RPCMethodDescriptor(
    "contacts.shouldShareContact", route: .contactsShouldShare, lane: .read,
    bridge: .selector("namePhotoShouldOffer"), macOSOnly: true),
  RPCMethodDescriptor(
    "contacts.shareContactCard", route: .contactsShare, lane: .mutation,
    bridge: .selector("namePhotoShare"), macOSOnly: true),
  RPCMethodDescriptor(
    "handles.check", route: .handlesCheck, lane: .read,
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

let rpcDispatchRoutes: [String: RPCDispatchRoute] = {
  var result: [String: RPCDispatchRoute] = [:]
  for descriptor in rpcMethodDescriptors {
    for name in descriptor.names { result[name] = descriptor.route }
  }
  return result
}()
