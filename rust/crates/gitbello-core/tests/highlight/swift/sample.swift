import Foundation

/// A bag of items.
@MainActor
public struct Bag<Element: Hashable> {
    private var items: [Element] = []
    static let maxItems = 64

    public mutating func add(_ item: Element) throws -> Bool {
        guard items.count < Self.maxItems else { throw BagError.full }
        items.append(item)
        let label = "Added \(item) (\(items.count) of \(Self.maxItems))"
        let raw = #"C:\no\escapes "here""#
        let hex = 0xFF; let d = 1.5e3 // trailing
        defer { print(label, raw) }
        return items.contains(item) && item != nil
    }
}

enum BagError: Error { case full }
protocol Container { associatedtype Item }
extension Bag: Container { typealias Item = Element }

#if DEBUG
let debug = true /* block */
#endif
