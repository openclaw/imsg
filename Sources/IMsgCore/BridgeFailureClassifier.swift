import Foundation

enum BridgeFailureClassifier {
  static func prepublicationError(
    action: BridgeAction,
    transport: DeliveryTransport,
    error: Error
  ) -> Error {
    if !action.isMutation, error is CancellationError { return CancellationError() }
    guard action.isMutation else {
      return IMsgBridgeError.bridgeNotReady(String(describing: error))
    }
    return DeliveryFailure(
      disposition: .notStarted,
      transport: transport,
      operation: action.rawValue,
      detail: "The bridge request could not be published: \(String(describing: error))"
    )
  }

  static func postpublicationError(
    action: BridgeAction,
    transport: DeliveryTransport,
    error: Error
  ) -> Error {
    if let failure = error as? DeliveryFailure { return failure }
    guard action.isMutation else { return error }
    return DeliveryFailure(
      disposition: .mayHaveCompleted,
      transport: transport,
      operation: action.rawValue,
      detail: "The bridge response was unusable after publication: \(String(describing: error))"
    )
  }

  static func deliveryFailure(
    action: BridgeAction,
    disposition: DeliveryDisposition,
    transport: DeliveryTransport,
    detail: String
  ) -> Error {
    guard action.isMutation else {
      return IMsgBridgeError.timeout(action: action.rawValue)
    }
    return DeliveryFailure(
      disposition: disposition,
      transport: transport,
      operation: action.rawValue,
      detail: detail
    )
  }

}
