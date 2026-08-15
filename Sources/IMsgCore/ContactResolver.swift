import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

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

  /// Headless stdin (LaunchAgent, pipes, automation) must not block on a
  /// Contacts prompt that will never resolve while authorization remains
  /// `.notDetermined`. Interactive terminals keep the prompt-capable path.
  public static func forStdin(isTTY: Bool) -> ContactsAccessPolicy {
    isTTY ? .requestIfNeeded : .skipIfNotDetermined
  }

  /// Whether the current process stdin is an interactive TTY.
  public static var stdinIsTTY: Bool {
    isatty(STDIN_FILENO) != 0
  }
}

/// A process-owned Contacts catalog. Reads stay synchronous for existing callers, while the
/// owner refreshes on Contacts notifications and a bounded TTL fallback.
public final class ContactResolver: ContactResolving, @unchecked Sendable {
  #if os(macOS)
    let source: ContactCatalogSource
    let refreshInterval: TimeInterval
    let maximumRegionSnapshots: Int
    let now: () -> TimeInterval
    let normalizer = PhoneNumberNormalizer()
    let condition = NSCondition()
    let defaultRegion: String

    var records: [ContactCatalogRecord] = []
    var snapshots: [String: ContactCatalogSnapshot] = [:]
    var regionRecency: [String] = []
    var nextRefreshAt: TimeInterval = -.infinity
    var invalidated = true
    var refreshing = false
    var authorizationWasAvailable = false
    var hasLastGoodCatalog = false
    var unavailable = true
    var cancelObservation: (() -> Void)?

    init(
      region: String,
      source: ContactCatalogSource,
      refreshInterval: TimeInterval = 30,
      maximumRegionSnapshots: Int = 8,
      now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
      self.defaultRegion = Self.normalizedRegion(region)
      self.source = source
      self.refreshInterval = max(0, refreshInterval)
      self.maximumRegionSnapshots = max(1, maximumRegionSnapshots)
      self.now = now
      self.cancelObservation = source.observeChanges { [weak self] in
        self?.invalidate()
      }
    }

    deinit {
      cancelObservation?()
    }
  #endif

  public static func create(
    region: String = "US",
    accessPolicy: ContactsAccessPolicy = .requestIfNeeded
  ) async -> any ContactResolving {
    #if os(macOS)
      let store = CNContactStore()
      let initialStatus = CNContactStore.authorizationStatus(for: .contacts)
      if initialStatus == .notDetermined, accessPolicy == .requestIfNeeded {
        _ = await requestAccess(store: store)
      }
      return ContactResolver(region: region, source: contactSource(store: store))
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
      let resolvedStatus: CNAuthorizationStatus
      if authorizationStatus == .notDetermined, accessPolicy == .requestIfNeeded {
        resolvedStatus = await requestAccess(store) ? .authorized : .denied
      } else {
        resolvedStatus = authorizationStatus
      }
      let source = ContactCatalogSource(
        authorization: { catalogAuthorization(resolvedStatus) },
        load: { try loadRecords(store: store) },
        observeChanges: { _ in {} }
      )
      return ContactResolver(region: region, source: source)
    }
  #endif

  public var contactsUnavailable: Bool {
    #if os(macOS)
      return snapshot(region: defaultRegion).unavailable
    #else
      return true
    #endif
  }

  public func resolver(region: String) -> any ContactResolving {
    #if os(macOS)
      let region = Self.normalizedRegion(region)
      if region == defaultRegion { return self }
      return ContactRegionResolver(owner: self, region: region)
    #else
      _ = region
      return self
    #endif
  }

  public func displayName(for handle: String) -> String? {
    #if os(macOS)
      return displayName(for: handle, region: defaultRegion)
    #else
      _ = handle
      return nil
    #endif
  }

  public func displayNames(for handles: [String]) -> [String: String] {
    #if os(macOS)
      return displayNames(for: handles, region: defaultRegion)
    #else
      _ = handles
      return [:]
    #endif
  }

  public func searchByName(_ query: String) -> [ContactMatch] {
    #if os(macOS)
      return searchByName(query, region: defaultRegion)
    #else
      _ = query
      return []
    #endif
  }
}
