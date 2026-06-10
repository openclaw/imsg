import Foundation

public enum MessageSendState: String, Sendable, Equatable {
  case pending
  case sent
  case delivered
  case failed
}

public struct MessageSendStatus: Sendable, Equatable {
  public let rowID: Int64
  public let guid: String
  public let service: String
  public let error: Int
  public let dateDelivered: Date?
  public let dateRead: Date?
  public let isSent: Bool
  public let isDelivered: Bool
  public let isFinished: Bool
  public let isDelayed: Bool
  public let isPrepared: Bool
  public let isPendingSatelliteSend: Bool
  public let wasDowngraded: Bool

  public var state: MessageSendState {
    if error != 0 { return .failed }
    if isDelivered || dateDelivered != nil { return .delivered }
    if isSent { return .sent }
    return .pending
  }

  public init(
    rowID: Int64,
    guid: String,
    service: String,
    error: Int,
    dateDelivered: Date?,
    dateRead: Date?,
    isSent: Bool,
    isDelivered: Bool,
    isFinished: Bool,
    isDelayed: Bool,
    isPrepared: Bool,
    isPendingSatelliteSend: Bool,
    wasDowngraded: Bool
  ) {
    self.rowID = rowID
    self.guid = guid
    self.service = service
    self.error = error
    self.dateDelivered = dateDelivered
    self.dateRead = dateRead
    self.isSent = isSent
    self.isDelivered = isDelivered
    self.isFinished = isFinished
    self.isDelayed = isDelayed
    self.isPrepared = isPrepared
    self.isPendingSatelliteSend = isPendingSatelliteSend
    self.wasDowngraded = wasDowngraded
  }
}
