import Foundation

/// The bare poll GUID a native vote associates to. Strips a leading
/// `p:<part>/` reference (the tapback-style form) if present; a plain GUID is
/// returned unchanged. Shared by the CLI and RPC vote paths.
package func barePollGuid(_ guid: String) -> String {
  guard let slash = guid.lastIndex(of: "/") else { return guid }
  let next = guid.index(after: slash)
  guard next < guid.endIndex else { return guid }
  return String(guid[next...])
}
