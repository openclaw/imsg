#if os(macOS)
  import Foundation
  @preconcurrency import Contacts

  enum ContactCatalogAuthorization: Equatable, Sendable {
    case authorized
    case notDetermined
    case unavailable
  }

  struct ContactCatalogRecord: Sendable {
    let name: String
    let phones: [String]
    let emails: [String]
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

    func displayName(for handle: String, region: String) -> String? {
      let state = snapshot(region: region)
      guard !state.unavailable else { return nil }
      let lookup = Self.normalizedLookupHandle(handle)
      if lookup.contains("@") {
        return state.catalog.emailToName[lookup.lowercased()]
      }
      let normalized = PhoneNumberNormalizer().normalize(lookup, region: region)
      return state.catalog.phoneToName[normalized]
    }

    func displayNames(for handles: [String], region: String) -> [String: String] {
      let state = snapshot(region: region)
      guard !state.unavailable else { return [:] }
      let lookupNormalizer = PhoneNumberNormalizer()
      var resolved: [String: String] = [:]
      for handle in handles {
        let lookup = Self.normalizedLookupHandle(handle)
        let name =
          lookup.contains("@")
          ? state.catalog.emailToName[lookup.lowercased()]
          : state.catalog.phoneToName[lookupNormalizer.normalize(lookup, region: region)]
        if let name { resolved[handle] = name }
      }
      return resolved
    }

    func searchByName(_ query: String, region: String) -> [ContactMatch] {
      let state = snapshot(region: region)
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
      region: String
    ) -> (catalog: ContactCatalogSnapshot, unavailable: Bool) {
      let region = Self.normalizedRegion(region)
      condition.lock()
      while true {
        let authorization = source.authorization()
        if authorization != .authorized {
          if refreshing {
            condition.wait()
            continue
          }
          apply(.unauthorized)
          let catalog = regionSnapshot(region)
          condition.unlock()
          return (catalog, true)
        }
        let authorizationBecameAvailable = !authorizationWasAvailable
        authorizationWasAvailable = true
        let shouldRefresh = authorizationBecameAvailable || invalidated || now() >= nextRefreshAt
        if shouldRefresh, refreshing {
          condition.wait()
          continue
        }
        if shouldRefresh {
          refreshing = true
          invalidated = false
          condition.unlock()
          let result = loadCatalog()
          condition.lock()
          apply(source.authorization() == .authorized ? result : .unauthorized)
          refreshing = false
          condition.broadcast()
          if invalidated { continue }
          let catalog = regionSnapshot(region)
          let isUnavailable = unavailable
          condition.unlock()
          return (catalog, isUnavailable)
        }

        let catalog = regionSnapshot(region)
        let isUnavailable = unavailable
        condition.unlock()
        return (catalog, isUnavailable)
      }
    }

    private enum LoadResult {
      case loaded([ContactCatalogRecord])
      case transientFailure
      case unauthorized
    }

    private func loadCatalog() -> LoadResult {
      guard source.authorization() == .authorized else { return .unauthorized }
      do {
        return .loaded(try source.load())
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
      case .unauthorized:
        authorizationWasAvailable = false
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
      case .denied, .restricted:
        return .unavailable
      @unknown default:
        return .unavailable
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

    init(owner: ContactResolver, region: String) {
      self.owner = owner
      self.region = region
    }

    var contactsUnavailable: Bool {
      owner.snapshot(region: region).unavailable
    }

    func displayName(for handle: String) -> String? {
      owner.displayName(for: handle, region: region)
    }

    func displayNames(for handles: [String]) -> [String: String] {
      owner.displayNames(for: handles, region: region)
    }

    func searchByName(_ query: String) -> [ContactMatch] {
      owner.searchByName(query, region: region)
    }
  }
#endif
