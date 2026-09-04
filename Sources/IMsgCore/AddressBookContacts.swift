#if os(macOS)
  import Foundation
  import SQLite
  import SQLite3

  enum AddressBookContacts {
    enum ReadError: Error {
      case unavailable
      case busy
    }

    static var directory: URL {
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AddressBook", isDirectory: true)
    }

    // SSH can have Full Disk Access without a Contacts.framework grant. Read the
    // existing v22 store in place, including its WAL; never copy or modify it.
    static func load(directory: URL) throws -> [ContactCatalogRecord] {
      do {
        let manager = FileManager.default
        let entries = try manager.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil)
        var directories: [URL] = []
        if let sources = entries.first(where: { $0.lastPathComponent == "Sources" }) {
          directories = try manager.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: [.isDirectoryKey]
          )
          .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
          .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        directories.append(directory)
        let databases = try directories.compactMap { directory -> URL? in
          // Enumerate instead of fileExists, which hides denied directory access.
          let files = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
          let versions = files.compactMap { file -> (Int, URL)? in
            let name = file.lastPathComponent
            guard name.hasPrefix("AddressBook-v"), name.hasSuffix(".abcddb"),
              let version = Int(name.dropFirst("AddressBook-v".count).dropLast(".abcddb".count))
            else { return nil }
            return (version, file)
          }
          guard let newest = versions.max(by: { $0.0 < $1.0 }) else { return nil }
          // An OS migration can leave an old database behind; never serve stale names from it.
          guard newest.0 == 22 else { throw ReadError.unavailable }
          return newest.1
        }
        guard !databases.isEmpty else { throw ReadError.unavailable }

        var records: [ContactCatalogRecord] = []
        for database in databases {
          records += try loadDatabase(database)
        }
        return records
      } catch SQLite.Result.error(_, let code, _) where code == SQLITE_BUSY || code == SQLITE_LOCKED
      {
        throw ReadError.busy
      } catch {
        // Missing permissions, files, or required columns invalidate old names;
        // a partial catalog must not masquerade as a successful read.
        throw ReadError.unavailable
      }
    }

    private static func loadDatabase(_ url: URL) throws -> [ContactCatalogRecord] {
      let db = try Connection(url.path, readonly: true)
      db.busyTimeout = 0.25
      let rows = try db.prepareRowIterator(
        """
        SELECT r.Z_PK AS id, r.ZNICKNAME AS nickname, r.ZFIRSTNAME AS first_name,
               r.ZLASTNAME AS last_name, p.ZFULLNUMBER AS phone, NULL AS email
        FROM ZABCDRECORD r JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
        UNION ALL
        SELECT r.Z_PK AS id, r.ZNICKNAME AS nickname, r.ZFIRSTNAME AS first_name,
               r.ZLASTNAME AS last_name, NULL AS phone, e.ZADDRESS AS email
        FROM ZABCDRECORD r JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
        ORDER BY id, phone, email
        """, bindings: [])
      var contacts: [Int64: ContactCatalogRecord] = [:]
      while let row = try rows.failableNext() {
        let id = try row.get(Expression<Int64>("id"))
        let nickname = try row.get(Expression<String?>("nickname")) ?? ""
        let first = try row.get(Expression<String?>("first_name")) ?? ""
        let last = try row.get(Expression<String?>("last_name")) ?? ""
        let name =
          nickname.isEmpty ? [first, last].filter { !$0.isEmpty }.joined(separator: " ") : nickname
        guard !name.isEmpty else { continue }
        if contacts[id] == nil {
          contacts[id] = ContactCatalogRecord(name: name, phones: [], emails: [])
        }
        if let phone = try row.get(Expression<String?>("phone")), !phone.isEmpty {
          contacts[id]?.phones.append(phone)
        }
        if let email = try row.get(Expression<String?>("email")), !email.isEmpty {
          contacts[id]?.emails.append(email)
        }
      }
      return contacts.keys.sorted().compactMap { contacts[$0] }
    }
  }

  extension ContactCatalogSource {
    func allowingAddressBook(at directory: URL) -> ContactCatalogSource {
      ContactCatalogSource(
        authorization: {
          switch authorization() {
          case .notDetermined, .unavailable: return .addressBook
          case let current: return current
          }
        },
        load: {
          switch authorization() {
          case .authorized: return try load()
          case .addressBook, .notDetermined, .unavailable:
            return try AddressBookContacts.load(directory: directory)
          case .restricted: throw AddressBookContacts.ReadError.unavailable
          }
        },
        observeChanges: observeChanges
      )
    }
  }
#endif
