import Foundation

#if os(macOS)
  @preconcurrency import Contacts
#endif

public struct ContactMatch: Equatable, Sendable {
  public let name: String
  public let handle: String

  public init(name: String, handle: String) {
    self.name = name
    self.handle = handle
  }
}

public protocol ContactResolving: Sendable {
  var contactsUnavailable: Bool { get }

  func displayName(for handle: String) -> String?
  func displayNames(for handles: [String]) -> [String: String]
  func searchByName(_ query: String) -> [ContactMatch]
}

public final class NoOpContactResolver: ContactResolving, Sendable {
  public let contactsUnavailable: Bool

  public init(contactsUnavailable: Bool = false) {
    self.contactsUnavailable = contactsUnavailable
  }

  public func displayName(for handle: String) -> String? { nil }
  public func displayNames(for handles: [String]) -> [String: String] { [:] }
  public func searchByName(_ query: String) -> [ContactMatch] { [] }
}

public enum ContactsAccessPolicy: Sendable {
  case requestIfNeeded
  case skipIfNotDetermined
}

public final class ContactResolver: ContactResolving, @unchecked Sendable {
  #if os(macOS)
    private let phoneToName: [String: String]
    private let emailToName: [String: String]
    private let contacts: [ContactRecord]
    private let normalizer = PhoneNumberNormalizer()
    private let region: String

    public let contactsUnavailable: Bool

    private init(
      phoneToName: [String: String],
      emailToName: [String: String],
      contacts: [ContactRecord],
      region: String
    ) {
      self.phoneToName = phoneToName
      self.emailToName = emailToName
      self.contacts = contacts
      self.region = region
      self.contactsUnavailable = false
    }
  #else
    public let contactsUnavailable = true
  #endif

  public static func create(
    region: String = "US",
    accessPolicy: ContactsAccessPolicy = .requestIfNeeded
  ) async -> any ContactResolving {
    #if os(macOS)
      let store = CNContactStore()
      return await create(
        region: region,
        accessPolicy: accessPolicy,
        store: store,
        authorizationStatus: CNContactStore.authorizationStatus(for: .contacts),
        requestAccess: requestAccess(store:)
      )
    #else
      _ = region
      _ = accessPolicy
      return NoOpContactResolver(contactsUnavailable: true)
    #endif
  }

  #if os(macOS)
    static func create(
      region: String = "US",
      accessPolicy: ContactsAccessPolicy = .requestIfNeeded,
      store: CNContactStore,
      authorizationStatus: CNAuthorizationStatus,
      requestAccess: @escaping (CNContactStore) async -> Bool
    ) async -> any ContactResolving {
      switch authorizationStatus {
      case .authorized:
        return load(store: store, region: region)
      case .notDetermined:
        guard accessPolicy == .requestIfNeeded else {
          return NoOpContactResolver(contactsUnavailable: true)
        }
        let granted = await requestAccess(store)
        return granted
          ? load(store: store, region: region) : NoOpContactResolver(contactsUnavailable: true)
      case .denied, .restricted:
        return NoOpContactResolver(contactsUnavailable: true)
      @unknown default:
        return NoOpContactResolver(contactsUnavailable: true)
      }
    }
  #endif

  public func displayName(for handle: String) -> String? {
    #if os(macOS)
      let lookup = normalizedLookupHandle(handle)
      if lookup.contains("@") {
        return emailToName[lookup.lowercased()]
      }
      return phoneToName[normalizer.normalize(lookup, region: region)]
    #else
      _ = handle
      return nil
    #endif
  }

  public func displayNames(for handles: [String]) -> [String: String] {
    #if os(macOS)
      var resolved: [String: String] = [:]
      for handle in handles {
        if let name = displayName(for: handle) {
          resolved[handle] = name
        }
      }
      return resolved
    #else
      _ = handles
      return [:]
    #endif
  }

  public func searchByName(_ query: String) -> [ContactMatch] {
    #if os(macOS)
      let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !normalizedQuery.isEmpty else { return [] }

      var matches: [ContactMatch] = []
      for contact in contacts where contact.name.lowercased().contains(normalizedQuery) {
        if let phone = contact.phones.first {
          matches.append(ContactMatch(name: contact.name, handle: phone))
        } else if let email = contact.emails.first {
          matches.append(ContactMatch(name: contact.name, handle: email))
        }
      }
      return matches
    #else
      _ = query
      return []
    #endif
  }

  #if os(macOS)
    private static func requestAccess(store: CNContactStore) async -> Bool {
      await withCheckedContinuation { continuation in
        store.requestAccess(for: .contacts) { granted, _ in
          continuation.resume(returning: granted)
        }
      }
    }

    private static func load(store: CNContactStore, region: String) -> any ContactResolving {
      let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
      ]
      let request = CNContactFetchRequest(keysToFetch: keysToFetch)
      let normalizer = PhoneNumberNormalizer()
      var phoneToName: [String: String] = [:]
      var emailToName: [String: String] = [:]
      var contacts: [ContactRecord] = []

      do {
        try store.enumerateContacts(with: request) { contact, _ in
          guard let name = displayName(for: contact) else { return }
          var phones: [String] = []
          var emails: [String] = []

          for number in contact.phoneNumbers {
            let normalized = normalizer.normalize(number.value.stringValue, region: region)
            phones.append(normalized)
            phoneToName[normalized] = phoneToName[normalized] ?? name
          }
          for email in contact.emailAddresses {
            let normalized = String(email.value).lowercased()
            emails.append(normalized)
            emailToName[normalized] = emailToName[normalized] ?? name
          }

          if !phones.isEmpty || !emails.isEmpty {
            contacts.append(ContactRecord(name: name, phones: phones, emails: emails))
          }
        }
      } catch {
        return NoOpContactResolver(contactsUnavailable: true)
      }

      return ContactResolver(
        phoneToName: phoneToName,
        emailToName: emailToName,
        contacts: contacts,
        region: region
      )
    }

    private static func displayName(for contact: CNContact) -> String? {
      if !contact.nickname.isEmpty {
        return contact.nickname
      }
      let name = [contact.givenName, contact.familyName]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      return name.isEmpty ? nil : name
    }

    private func normalizedLookupHandle(_ handle: String) -> String {
      let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
      for prefix in ["iMessage;-;", "iMessage;+;", "SMS;-;", "SMS;+;", "any;-;", "any;+;"]
      where trimmed.hasPrefix(prefix) {
        return String(trimmed.dropFirst(prefix.count))
      }
      return trimmed
    }
  #endif
}

#if os(macOS)
  private struct ContactRecord: Sendable {
    let name: String
    let phones: [String]
    let emails: [String]
  }
#endif
