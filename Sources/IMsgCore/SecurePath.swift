import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Preserves lexical path components so symlinks cannot disappear through `..`
/// normalization. Only macOS's trusted system aliases are expanded.
public enum SecurePath {
  private static func normalizingTrustedSystemAliasPrefix(_ path: String) -> String {
    let aliases = [
      "/tmp": "/private/tmp",
      "/var": "/private/var",
      "/etc": "/private/etc",
    ]
    for (alias, canonical) in aliases {
      if path == alias {
        return canonical
      }
      if path.hasPrefix(alias + "/") {
        return canonical + path.dropFirst(alias.count)
      }
    }
    return path
  }

  private static func absoluteExpandedPath(_ path: String) -> String {
    var lexicalPath = (path as NSString).expandingTildeInPath
    if !lexicalPath.hasPrefix("/") {
      lexicalPath =
        (FileManager.default.currentDirectoryPath as NSString)
        .appendingPathComponent(lexicalPath)
    }
    return lexicalPath
  }

  static func absoluteLexicalPath(_ path: String) -> String {
    normalizingTrustedSystemAliasPrefix(absoluteExpandedPath(path))
  }

  /// Returns true if any component of `path` (after tilde expansion and CWD
  /// resolution for relative paths) is a symbolic link. Final component
  /// included.
  public static func hasSymlinkComponent(_ path: String) -> Bool {
    let lexicalPath = absoluteLexicalPath(path)

    let components = (lexicalPath as NSString).pathComponents
    guard !components.isEmpty else { return false }

    var cursor = components.first == "/" ? "/" : ""
    for component in components where component != "/" && !component.isEmpty {
      cursor = (cursor as NSString).appendingPathComponent(component)

      var info = stat()
      if lstat(cursor, &info) != 0 {
        continue
      }
      if (info.st_mode & S_IFMT) == S_IFLNK {
        return true
      }
    }
    return false
  }
}
