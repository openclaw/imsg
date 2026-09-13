import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg

func rpcTestInt64Value(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}
