#if os(macOS)
  import Foundation
  @preconcurrency import Contacts

  enum ContactCatalogAuthorization: Equatable, Sendable {
    case authorized
    case addressBook
    case notDetermined
    case unavailable
    case restricted

    var canAttemptRead: Bool { self == .authorized || self == .addressBook }
  }

  struct ContactCatalogRecord: Sendable {
    let name: String
    var phones: [String]
    var emails: [String]
  }

  struct ContactCatalogSource: @unchecked Sendable {
    let authorization: () -> ContactCatalogAuthorization
    let load: () throws -> [ContactCatalogRecord]
    let observeChanges: (@escaping @Sendable () -> Void) -> (() -> Void)
  }

  struct ContactCatalogSnapshot: Sendable {
    let phoneToName: [String: String]
    let emailToName: [String: String]
    let contacts: [ContactCatalogRecord]
  }

  extension ContactResolver {
    var cachedRegionCount: Int {
      condition.lock()
      defer { condition.unlock() }
      return snapshots.count
    }

    func displayName(for handle: String, region: String, waitForRefresh: Bool = true) -> String? {
      let state = snapshot(region: region, waitForRefresh: waitForRefresh)
      guard !state.unavailable else { return nil }
      let lookup = Self.normalizedLookupHandle(handle)
      if lookup.contains("@") {
        return state.catalog.emailToName[lookup.lowercased()]
      }
      // Reuse parsed phone metadata under the catalog's lock, including concurrent lookups.
      condition.lock()
      defer { condition.unlock() }
      let normalized = normalizer.normalize(lookup, region: region)
      return state.catalog.phoneToName[normalized]
    }

    func displayNames(
      for handles: [String], region: String, waitForRefresh: Bool = true
    ) -> [String: String] {
      let state = snapshot(region: region, waitForRefresh: waitForRefresh)
      guard !state.unavailable else { return [:] }
      condition.lock()
      defer { condition.unlock() }
      var resolved: [String: String] = [:]
      for handle in handles {
        let lookup = Self.normalizedLookupHandle(handle)
        let name =
          lookup.contains("@")
          ? state.catalog.emailToName[lookup.lowercased()]
          : state.catalog.phoneToName[normalizer.normalize(lookup, region: region)]
        if let name { resolved[handle] = name }
      }
      return resolved
    }

    func searchByName(
      _ query: String, region: String, waitForRefresh: Bool = true
    ) -> [ContactMatch] {
      let state = snapshot(region: region, waitForRefresh: waitForRefresh)
      guard !state.unavailable else { return [] }
      let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !query.isEmpty else { return [] }

      var matches: [ContactMatch] = []
      for contact in state.catalog.contacts where contact.name.lowercased().contains(query) {
        if let phone = contact.phones.first {
          matches.append(ContactMatch(name: contact.name, handle: phone))
        } else if let email = contact.emails.first {
          matches.append(ContactMatch(name: contact.name, handle: email))
        }
      }
      return matches
    }

    func invalidate() {
      condition.lock()
      invalidated = true
      condition.broadcast()
      condition.unlock()
    }

    func snapshot(
      region: String, waitForRefresh: Bool = true
    ) -> (catalog: ContactCatalogSnapshot, unavailable: Bool) {
      let region = Self.normalizedRegion(region)
      condition.lock()
      defer { condition.unlock() }
      while true {
        let authorization = source.authorization()
        if lastAuthorization != authorization {
          // A cached reader must clear revoked/source-switched data even during a stalled load.
          apply(.unauthorized)
          lastAuthorization = authorization
          authorizationGeneration &+= 1
          invalidated = true
        }
        if !authorization.canAttemptRead {
          return (regionSnapshot(region), true)
        }
        if refreshing {
          if !waitForRefresh { return (regionSnapshot(region), unavailable) }
          condition.wait()
          continue
        }
        if invalidated || now() >= nextRefreshAt {
          refreshing = true
          invalidated = false
          let generation = authorizationGeneration
          if !waitForRefresh {
            refreshQueue.async {
              let result = self.loadCatalog()
              self.condition.lock()
              defer { self.condition.unlock() }
              self.finishRefresh(result, authorization: authorization, generation: generation)
            }
            return (regionSnapshot(region), unavailable)
          }
          condition.unlock()
          let result = loadCatalog()
          condition.lock()
          // Publish and decide under the same lock; a cached caller must not consume
          // an invalidation and start another refresh before this caller resumes.
          finishRefresh(result, authorization: authorization, generation: generation)
          if invalidated { continue }
        }
        return (regionSnapshot(region), unavailable)
      }
    }

    private func finishRefresh(
      _ result: LoadResult, authorization: ContactCatalogAuthorization, generation: UInt64
    ) {
      // Also reject a read that spans an observed revoke/regrant of the same source.
      let sourceChanged =
        source.authorization() != authorization || authorizationGeneration != generation
      apply(sourceChanged ? .unauthorized : result)
      if sourceChanged { invalidated = true }
      refreshing = false
      condition.broadcast()
    }

    private enum LoadResult {
      case loaded([ContactCatalogRecord])
      case transientFailure
      case unauthorized
      case unavailable
    }

    private func loadCatalog() -> LoadResult {
      guard source.authorization().canAttemptRead else { return .unauthorized }
      do {
        return .loaded(try source.load())
      } catch AddressBookContacts.ReadError.unavailable {
        return .unavailable
      } catch {
        return .transientFailure
      }
    }

    private func apply(_ result: LoadResult) {
      nextRefreshAt = now() + refreshInterval
      switch result {
      case .loaded(let loaded):
        records = loaded
        snapshots.removeAll(keepingCapacity: true)
        regionRecency.removeAll(keepingCapacity: true)
        hasLastGoodCatalog = true
        unavailable = false
      case .transientFailure:
        unavailable = !hasLastGoodCatalog
      case .unauthorized, .unavailable:
        if case .unauthorized = result { lastAuthorization = nil }
        records.removeAll(keepingCapacity: false)
        snapshots.removeAll(keepingCapacity: false)
        regionRecency.removeAll(keepingCapacity: false)
        hasLastGoodCatalog = false
        unavailable = true
      }
    }

    private func regionSnapshot(_ region: String) -> ContactCatalogSnapshot {
      if let existing = snapshots[region] {
        touch(region)
        return existing
      }

      var phoneToName: [String: String] = [:]
      var emailToName: [String: String] = [:]
      var normalizedContacts: [ContactCatalogRecord] = []
      normalizedContacts.reserveCapacity(records.count)
      for contact in records {
        let phones = contact.phones.map { normalizer.normalize($0, region: region) }
        let emails = contact.emails.map { $0.lowercased() }
        for phone in phones {
          phoneToName[phone] = phoneToName[phone] ?? contact.name
        }
        for email in emails {
          emailToName[email] = emailToName[email] ?? contact.name
        }
        normalizedContacts.append(
          ContactCatalogRecord(name: contact.name, phones: phones, emails: emails))
      }
      let created = ContactCatalogSnapshot(
        phoneToName: phoneToName,
        emailToName: emailToName,
        contacts: normalizedContacts
      )
      snapshots[region] = created
      touch(region)
      while snapshots.count > maximumRegionSnapshots, let oldest = regionRecency.first {
        regionRecency.removeFirst()
        snapshots.removeValue(forKey: oldest)
      }
      return created
    }

    private func touch(_ region: String) {
      regionRecency.removeAll { $0 == region }
      regionRecency.append(region)
    }

    static func normalizedRegion(_ region: String) -> String {
      let normalized = region.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      return normalized.isEmpty ? "US" : normalized
    }

    private static func normalizedLookupHandle(_ handle: String) -> String {
      let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
      for prefix in ["iMessage;-;", "iMessage;+;", "SMS;-;", "SMS;+;", "any;-;", "any;+;"]
      where trimmed.hasPrefix(prefix) {
        return String(trimmed.dropFirst(prefix.count))
      }
      return trimmed
    }

    static func requestAccess(store: CNContactStore) async -> Bool {
      await withCheckedContinuation { continuation in
        store.requestAccess(for: .contacts) { granted, _ in
          continuation.resume(returning: granted)
        }
      }
    }

    static func contactSource(store: CNContactStore) -> ContactCatalogSource {
      ContactCatalogSource(
        authorization: {
          catalogAuthorization(CNContactStore.authorizationStatus(for: .contacts))
        },
        load: { try loadRecords(store: store) },
        observeChanges: { changed in
          let center = NotificationCenter.default
          let token = center.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: nil
          ) { _ in
            changed()
          }
          return { center.removeObserver(token) }
        }
      )
    }

    static func catalogAuthorization(
      _ authorizationStatus: CNAuthorizationStatus
    ) -> ContactCatalogAuthorization {
      switch authorizationStatus {
      case .authorized:
        return .authorized
      case .notDetermined:
        return .notDetermined
      case .denied:
        return .unavailable
      case .restricted:
        return .restricted
      @unknown default:
        return .restricted
      }
    }

    static func loadRecords(store: CNContactStore) throws -> [ContactCatalogRecord] {
      let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
      ]
      let request = CNContactFetchRequest(keysToFetch: keysToFetch)
      var contacts: [ContactCatalogRecord] = []
      try store.enumerateContacts(with: request) { contact, _ in
        guard let name = displayName(for: contact) else { return }
        let phones = contact.phoneNumbers.map(\.value.stringValue)
        let emails = contact.emailAddresses.map { String($0.value) }
        if !phones.isEmpty || !emails.isEmpty {
          contacts.append(ContactCatalogRecord(name: name, phones: phones, emails: emails))
        }
      }
      return contacts
    }

    private static func displayName(for contact: CNContact) -> String? {
      if !contact.nickname.isEmpty { return contact.nickname }
      let name = [contact.givenName, contact.familyName]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      return name.isEmpty ? nil : name
    }
  }

  final class ContactRegionResolver: ContactResolving, Sendable {
    private let owner: ContactResolver
    private let region: String
    private let waitForRefresh: Bool

    init(owner: ContactResolver, region: String, waitForRefresh: Bool = true) {
      self.owner = owner
      self.region = region
      self.waitForRefresh = waitForRefresh
    }

    var cached: any ContactResolving {
      ContactRegionResolver(owner: owner, region: region, waitForRefresh: false)
    }

    var contactsUnavailable: Bool {
      owner.snapshot(region: region, waitForRefresh: waitForRefresh).unavailable
    }

    func displayName(for handle: String) -> String? {
      owner.displayName(for: handle, region: region, waitForRefresh: waitForRefresh)
    }

    func displayNames(for handles: [String]) -> [String: String] {
      owner.displayNames(for: handles, region: region, waitForRefresh: waitForRefresh)
    }

    func searchByName(_ query: String) -> [ContactMatch] {
      owner.searchByName(query, region: region, waitForRefresh: waitForRefresh)
    }
  }
#endif
