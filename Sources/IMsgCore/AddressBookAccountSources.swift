#if os(macOS)
  import Foundation
  import SQLite

  extension AddressBookContacts {
    static var accountsDatabaseURL: URL {
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Accounts/Accounts4.sqlite")
    }

    // A Contacts account can inherit delegation from its parent iCloud account.
    // Read only the identifiers, parent links and delegation flags needed for ordering.
    static func childDelegateSourceIdentifiers(accountsDatabase: URL?) -> Set<String> {
      guard let accountsDatabase else { return [] }
      do {
        let db = try Connection(accountsDatabase.path, readonly: true)
        db.busyTimeout = 0.25
        let accounts = try db.prepareRowIterator(
          "SELECT Z_PK AS id, ZIDENTIFIER AS identifier, ZPARENTACCOUNT AS parent FROM ZACCOUNT",
          bindings: [])
        var identifiers: [Int64: String] = [:]
        var parents: [Int64: Int64] = [:]
        while let row = try accounts.failableNext() {
          let id = try row.get(Expression<Int64>("id"))
          identifiers[id] = try row.get(Expression<String?>("identifier"))?.lowercased()
          parents[id] = try row.get(Expression<Int64?>("parent"))
        }
        let properties = try db.prepareRowIterator(
          "SELECT ZOWNER AS owner, ZVALUE AS value FROM ZACCOUNTPROPERTY WHERE ZKEY = 'isChildDelegate'",
          bindings: [])
        var delegated = Set<Int64>()
        while let row = try properties.failableNext() {
          guard let blob = try row.get(Expression<Blob?>("value")),
            let flag = try NSKeyedUnarchiver.unarchivedObject(
              ofClass: NSNumber.self, from: Data(blob.bytes)), flag.boolValue
          else { continue }
          delegated.insert(try row.get(Expression<Int64>("owner")))
        }
        var result = Set<String>()
        for (id, identifier) in identifiers {
          var ancestor: Int64? = id
          var visited = Set<Int64>()
          while let current = ancestor, visited.insert(current).inserted {
            if delegated.contains(current) {
              result.insert(identifier)
              break
            }
            ancestor = parents[current]
          }
        }
        return result
      } catch {
        // Account metadata is optional; its absence must not disable Contacts reads.
        return []
      }
    }
  }
#endif
