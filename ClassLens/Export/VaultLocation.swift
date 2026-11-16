import Foundation

/// Where a lecture goes in the student's Obsidian vault, inferred from where its slides live:
/// slides at `<vault>/模块/<课程>/资料/课件/…` put the export in `<vault>/模块/<课程>/资料/课堂记录/ClassLens/`.
struct VaultLocation: Equatable, Sendable {
    var vaultRoot: URL
    var course: String

    static let modules = "模块"

    /// The export folder and its three subfolders, as agreed with the student (CLAUDE.md, M6).
    var classLensFolder: URL {
        vaultRoot.appending(path: "\(Self.modules)/\(course)/资料/课堂记录/ClassLens", directoryHint: .isDirectory)
    }

    static func infer(fromSlidesAt path: String) -> VaultLocation? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let index = components.firstIndex(of: modules), index + 1 < components.count - 1 else { return nil }
        let root = NSString.path(withComponents: Array(components[..<index]))
        return VaultLocation(vaultRoot: URL(fileURLWithPath: root, isDirectory: true), course: components[index + 1])
    }

    /// The teaching week in a path such as "SCEM_Week7_Materials" or "W07"; nil if none is found.
    static func week(fromSlidesAt path: String) -> Int? {
        let patterns = [#"(?i)week[ _-]?0*(\d{1,2})"#, #"(?<![A-Za-z])W0*(\d{1,2})(?!\d)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
                  let range = Range(match.range(at: 1), in: path), let week = Int(path[range]) else { continue }
            return week
        }
        return nil
    }
}
