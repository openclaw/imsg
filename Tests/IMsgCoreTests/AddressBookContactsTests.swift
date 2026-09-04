#if os(macOS)
  import Foundation
  import SQLite
  import Testing

  @testable import IMsgCore

  private func addressBookFixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func addressBookFixture(_ directory: URL, source: String? = nil) throws -> Connection {
    let directory = source.map { directory.appendingPathComponent("Sources/\($0)") } ?? directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let db = try Connection(directory.appendingPathComponent("AddressBook-v22.abcddb").path)
    try db.execute(
      """
      CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZNICKNAME TEXT, ZFIRSTNAME TEXT, ZLASTNAME TEXT);
      CREATE TABLE ZABCDPHONENUMBER (ZOWNER INTEGER, ZFULLNUMBER TEXT);
      CREATE TABLE ZABCDEMAILADDRESS (ZOWNER INTEGER, ZADDRESS TEXT);
      """)
    return db
  }

  private func addAddressBookContact(
    _ db: Connection, name: String, phone: String, email: String
  ) throws {
    try db.run("INSERT INTO ZABCDRECORD VALUES (1, '', ?, 'Example')", name)
    try db.run("INSERT INTO ZABCDPHONENUMBER VALUES (1, ?)", phone)
    try db.run("INSERT INTO ZABCDEMAILADDRESS VALUES (1, ?)", email)
  }

  private func addressBookResolver(
    _ directory: URL, authorization: ContactCatalogAuthorization = .notDetermined
  ) -> ContactResolver {
    let source = ContactCatalogSource(
      authorization: { authorization },
      load: { [ContactCatalogRecord(name: "Native", phones: ["+14155550111"], emails: [])] },
      observeChanges: { _ in {} }
    )
    return ContactResolver(
      region: "US", source: source.allowingAddressBook(at: directory), refreshInterval: 0)
  }

  @Test
  func addressBookResolvesLocalAndAccountContactsWithSharedNormalization() throws {
    let directory = try addressBookFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = try addressBookFixture(directory)
    let account = try addressBookFixture(directory, source: "account-a")
    try addAddressBookContact(
      local, name: "Ada", phone: "+1 (415) 555-0111", email: "ADA@example.invalid")
    try addAddressBookContact(
      account, name: "Grace", phone: "+14155550222", email: "grace@example.invalid")
    try account.run("UPDATE ZABCDRECORD SET ZNICKNAME = 'Amazing Grace'")
    let resolver = addressBookResolver(directory)

    #expect(!resolver.contactsUnavailable)
    #expect(resolver.displayName(for: "+14155550111") == "Ada Example")
    #expect(resolver.displayName(for: "iMessage;-;+14155550222") == "Amazing Grace")
    #expect(resolver.displayName(for: "ada@example.invalid") == "Ada Example")
    #expect(resolver.displayName(for: "GRACE@example.invalid") == "Amazing Grace")
    #expect(resolver.displayName(for: "missing@example.invalid") == nil)
    #expect(
      resolver.searchByName("Grace") == [
        ContactMatch(name: "Amazing Grace", handle: "+14155550222")
      ])
  }

  @Test(arguments: [
    ContactCatalogAuthorization.authorized, .notDetermined, .unavailable, .restricted,
  ])
  func addressBookFallbackPreservesNativeAndRestrictedAccess(
    authorization: ContactCatalogAuthorization
  ) throws {
    let directory = try addressBookFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try addressBookFixture(directory)
    try addAddressBookContact(db, name: "Ada", phone: "+14155550111", email: "ada@example.invalid")
    let resolver = addressBookResolver(directory, authorization: authorization)

    let expected: String?
    switch authorization {
    case .authorized: expected = "Native"
    case .restricted: expected = nil
    case .addressBook, .notDetermined, .unavailable: expected = "Ada Example"
    }
    #expect(resolver.displayName(for: "+14155550111") == expected)
    #expect(resolver.contactsUnavailable == (authorization == .restricted))
  }

  @Test(arguments: ["empty", "missing", "unsupported"])
  func addressBookDistinguishesUnavailableStoresFromNoMatch(kind: String) throws {
    let directory = try addressBookFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    if kind != "missing" {
      let db = try addressBookFixture(directory)
      if kind == "unsupported" { try db.execute("DROP TABLE ZABCDPHONENUMBER") }
    }
    let resolver = addressBookResolver(directory)
    #expect(resolver.displayName(for: "+14155550111") == nil)
    #expect(resolver.contactsUnavailable == (kind != "empty"))
    if kind == "missing" {
      #expect(
        !FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("AddressBook-v22.abcddb").path))
    }
  }

  @Test
  func addressBookRefreshSeesWALUpdatesAndClearsNamesWhenStoreDisappears() throws {
    let directory = try addressBookFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try addressBookFixture(directory)
    try db.execute("PRAGMA journal_mode = WAL")
    try addAddressBookContact(db, name: "Ada", phone: "+14155550111", email: "ada@example.invalid")
    let resolver = addressBookResolver(directory)
    #expect(resolver.displayName(for: "+14155550111") == "Ada Example")

    try db.execute("BEGIN IMMEDIATE")
    try db.execute("UPDATE ZABCDRECORD SET ZNICKNAME = 'Updated'")
    #expect(resolver.displayName(for: "+14155550111") == "Ada Example")
    try db.execute("COMMIT")
    #expect(resolver.displayName(for: "+14155550111") == "Updated")

    try FileManager.default.removeItem(
      at: directory.appendingPathComponent("AddressBook-v22.abcddb"))
    #expect(resolver.displayName(for: "+14155550111") == nil)
    #expect(resolver.contactsUnavailable)
  }

  @Test
  func addressBookDoesNotReturnPartialCatalogForUnreadableAccount() throws {
    let directory = try addressBookFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try addressBookFixture(directory)
    try addAddressBookContact(db, name: "Ada", phone: "+14155550111", email: "ada@example.invalid")
    let broken = try addressBookFixture(directory, source: "account-b")
    try broken.execute("DROP TABLE ZABCDRECORD")
    let resolver = addressBookResolver(directory)
    #expect(resolver.displayName(for: "+14155550111") == nil)
    #expect(resolver.contactsUnavailable)
  }

  @Test
  func addressBookRetainsLastCatalogWhileDatabaseIsBusy() throws {
    let directory = try addressBookFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try addressBookFixture(directory)
    try addAddressBookContact(db, name: "Ada", phone: "+14155550111", email: "ada@example.invalid")
    let resolver = addressBookResolver(directory)
    #expect(resolver.displayName(for: "+14155550111") == "Ada Example")
    try db.execute("BEGIN EXCLUSIVE")
    defer { try? db.execute("ROLLBACK") }
    #expect(resolver.displayName(for: "+14155550111") == "Ada Example")
    #expect(!resolver.contactsUnavailable)
  }
  @Test
  func addressBookRejectsUnreadableAccountDirectory() throws {
    let directory = try addressBookFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try addressBookFixture(directory)
    try addAddressBookContact(db, name: "Ada", phone: "+14155550111", email: "ada@example.invalid")
    _ = try addressBookFixture(directory, source: "denied")
    let denied = directory.appendingPathComponent("Sources/denied")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
    }
    let resolver = addressBookResolver(directory)
    let name = resolver.displayName(for: "+14155550111")
    let unavailable = resolver.contactsUnavailable
    #expect(name == nil)
    #expect(unavailable)
  }

  @Test
  func addressBookRejectsRetiredStoreWhenNewerVersionExists() throws {
    let directory = try addressBookFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try addressBookFixture(directory)
    try addAddressBookContact(db, name: "Ada", phone: "+14155550111", email: "ada@example.invalid")
    try Data().write(to: directory.appendingPathComponent("AddressBook-v23.abcddb"))
    let resolver = addressBookResolver(directory)
    let name = resolver.displayName(for: "+14155550111")
    let unavailable = resolver.contactsUnavailable
    #expect(name == nil)
    #expect(unavailable)
  }
  @Test(arguments: ["missing", "readable", "locked"])
  func addressBookSourceChangesInvalidateCachedNativeNames(databaseState: String) throws {
    let directory = try addressBookFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var database: Connection?
    if databaseState != "missing" {
      let db = try addressBookFixture(directory)
      try addAddressBookContact(
        db, name: "Ada", phone: "+14155550111", email: "ada@example.invalid")
      database = db
    }
    var authorization = ContactCatalogAuthorization.authorized
    let native = ContactCatalogSource(
      authorization: { authorization },
      load: { [ContactCatalogRecord(name: "Native", phones: ["+14155550111"], emails: [])] },
      observeChanges: { _ in {} }
    )
    let resolver = ContactResolver(
      region: "US", source: native.allowingAddressBook(at: directory), refreshInterval: 60)
    let before = resolver.displayName(for: "+14155550111")
    #expect(before == "Native")
    if databaseState == "locked" { try #require(database).execute("BEGIN EXCLUSIVE") }
    defer { if databaseState == "locked" { try? database?.execute("ROLLBACK") } }
    authorization = .unavailable
    let after = resolver.displayName(for: "+14155550111")
    let unavailable = resolver.contactsUnavailable
    #expect(after == (databaseState == "readable" ? "Ada Example" : nil))
    #expect(unavailable == (databaseState != "readable"))
    authorization = .authorized
    let restored = resolver.displayName(for: "+14155550111")
    #expect(restored == "Native")
  }
#endif
