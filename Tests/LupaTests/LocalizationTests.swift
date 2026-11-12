import Foundation
import Testing

@testable import Lupa

struct LocalizationTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    @Test(arguments: ["pt-BR.lproj/Localizable.strings", "pt-BR.lproj/InfoPlist.strings", "en.lproj/InfoPlist.strings"])
    func stringsFileParses(path: String) throws {
        let table = try Self.table(path)
        #expect(!table.isEmpty)
    }

    @Test func translationsKeepFormatSpecifiers() throws {
        for (key, value) in try Self.table("pt-BR.lproj/Localizable.strings") {
            #expect(Self.specifiers(key) == Self.specifiers(value), "\(key)")
        }
    }

    @Test func fileNamesAreSortable() {
        let date = DateComponents(calendar: .current, year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5).date!
        #expect(FileNames.timestamped("mov", date: date) == "Lupa 2026-01-02 at 03.04.05.mov")
    }

    @Test func zoomLabels() {
        #expect(CGFloat(2).zoomLabel.hasPrefix("2"))
        #expect(CGFloat(2).zoomLabel.hasSuffix("×"))
        #expect(CGFloat(1.5).zoomLabel.count == "1.5×".count)
    }

    private static func table(_ path: String) throws -> [String: String] {
        let data = try Data(contentsOf: resources.appendingPathComponent(path))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: String])
    }

    private static func specifiers(_ text: String) -> [String] {
        let regex = #/%(?:\d+\$)?(?:@|lld|ld|d|lf|f)/#
        return text.matches(of: regex).map { String($0.output) }
    }
}
