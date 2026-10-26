import Foundation
import Darwin

struct TrashServiceSmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private struct TrashedItem {
        let destination: URL
        let relativePayload: String?
        let payload: Data

        var payloadURL: URL {
            relativePayload.map { destination.appendingPathComponent($0) } ?? destination
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func write(_ payload: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: url, options: .withoutOverwriting)
    }

    private static func trash(
        _ target: PermanentDeletionTarget, service: PermanentDeletionService,
        relativePayload: String? = nil, payload: Data, returned: inout [TrashedItem]
    ) async throws -> URL {
        let destination = try await service.trash(target)
        // Track the exact returned object before assertions, so assertion failures also clean up.
        let item = TrashedItem(destination: destination, relativePayload: relativePayload, payload: payload)
        returned.append(item)
        try check(destination.standardizedFileURL != target.url.standardizedFileURL, "Trash returned the original path")
        try check(!FileManager.default.fileExists(atPath: target.url.path), "Trash left the original item in place")
        let actual = try Data(contentsOf: item.payloadURL)
        try check(actual == payload, "Trash did not preserve the fixture bytes at its returned destination")
        return destination
    }

    private static func cleanup(_ returned: [TrashedItem]) throws {
        for item in returned {
            // Never enumerate or empty Trash. Only remove exact returned paths whose
            // unique fixture bytes still establish ownership, even after a failed assertion.
            guard FileManager.default.fileExists(atPath: item.destination.path) else { continue }
            let actual = try Data(contentsOf: item.payloadURL)
            try check(actual == item.payload, "Refusing to clean up a Trash item no longer owned by this test")
            try FileManager.default.removeItem(at: item.destination)
        }
    }

    static func run(root: URL) async throws {
        let manager = FileManager.default
        let identifier = UUID().uuidString
        let fixture = root.appendingPathComponent("dix-trash-\(identifier)", isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let service = PermanentDeletionService()
        var returned: [TrashedItem] = []
        do {
            let file = fixture.appendingPathComponent("dix-trash-file-\(identifier).bin")
            let firstBytes = Data("first file \(identifier)".utf8)
            try write(firstBytes, to: file)
            let firstTarget = try await service.prepare(url: file, scanRoot: fixture)
            let firstDestination = try await trash(firstTarget, service: service, payload: firstBytes, returned: &returned)

            // Keep the first entry in Trash and reuse precisely the same basename.
            let secondBytes = Data("second file \(identifier)".utf8)
            try write(secondBytes, to: file)
            let secondTarget = try await service.prepare(url: file, scanRoot: fixture)
            let secondDestination = try await trash(secondTarget, service: service, payload: secondBytes, returned: &returned)
            try check(firstDestination.standardizedFileURL != secondDestination.standardizedFileURL, "A Trash name collision reused the first destination")
            let preservedFirst = try Data(contentsOf: firstDestination)
            try check(preservedFirst == firstBytes, "A Trash name collision overwrote the earlier entry")

            let directory = fixture.appendingPathComponent("dix-trash-directory-\(identifier)", isDirectory: true)
            let directoryBytes = Data("nested directory payload \(identifier)".utf8)
            let nestedPayload = "Nested/payload.bin"
            try write(directoryBytes, to: directory.appendingPathComponent(nestedPayload))
            let directoryTarget = try await service.prepare(url: directory, scanRoot: fixture)
            _ = try await trash(directoryTarget, service: service, relativePayload: nestedPayload, payload: directoryBytes, returned: &returned)

            let package = fixture.appendingPathComponent("dix-trash-package-\(identifier).app", isDirectory: true)
            let packageBytes = Data("package payload \(identifier)".utf8)
            let packagePayload = "Contents/Resources/payload.bin"
            try write(packageBytes, to: package.appendingPathComponent(packagePayload))
            let info: [String: Any] = [
                "CFBundleIdentifier": "org.diskinventoryx2.trash-smoke.\(identifier)",
                "CFBundleName": "Trash Smoke Fixture",
                "CFBundlePackageType": "APPL"
            ]
            let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try infoData.write(to: package.appendingPathComponent("Contents/Info.plist"))
            let packageValues = try package.resourceValues(forKeys: [.isPackageKey])
            try check(packageValues.isPackage == true, "Fixture is not recognized as a package")
            let packageTarget = try await service.prepare(url: package, scanRoot: fixture)
            let packageDestination = try await trash(packageTarget, service: service, relativePayload: packagePayload, payload: packageBytes, returned: &returned)
            let preservedInfo = try Data(contentsOf: packageDestination.appendingPathComponent("Contents/Info.plist"))
            try check(preservedInfo == infoData, "Trash lost package metadata")

            try await verifyIdentityReplacement(root: fixture, service: service, returned: &returned)
            do {
                _ = try await service.prepare(url: fixture, scanRoot: fixture)
                throw Failure(description: "Trash preflight accepted its protected scan root")
            } catch PermanentDeletionError.protectedLocation {}
            try check(manager.fileExists(atPath: fixture.path), "Protected-root rejection removed the root")
            try await verifyFilesystemFailure(root: fixture, service: service, returned: &returned)
            try cleanup(returned)
        } catch {
            try? cleanup(returned)
            throw error
        }
        print("PASS: real Trash file/directory/package moves preserve bytes; collision destinations remain separate; replaced identity and scan root rejected; filesystem failure preserves the original; only exact owned Trash entries cleaned up")
    }

    private static func verifyIdentityReplacement(
        root: URL, service: PermanentDeletionService, returned: inout [TrashedItem]
    ) async throws {
        let original = root.appendingPathComponent("identity-\(UUID().uuidString).bin")
        let saved = root.appendingPathComponent("saved-\(UUID().uuidString).bin")
        let originalBytes = Data("original \(UUID().uuidString)".utf8)
        let replacementBytes = Data("replacement \(UUID().uuidString)".utf8)
        try write(originalBytes, to: original)
        let target = try await service.prepare(url: original, scanRoot: root)
        // Retaining the old inode prevents inode reuse from weakening this check.
        try FileManager.default.moveItem(at: original, to: saved)
        try write(replacementBytes, to: original)
        do {
            _ = try await trash(target, service: service, payload: replacementBytes, returned: &returned)
            throw Failure(description: "Trash accepted a replacement at the confirmed pathname")
        } catch PermanentDeletionError.changedItem {}
        let actualReplacement = try Data(contentsOf: original)
        let actualOriginal = try Data(contentsOf: saved)
        try check(actualReplacement == replacementBytes && actualOriginal == originalBytes, "Identity rejection changed either fixture")
    }

    private static func verifyFilesystemFailure(
        root: URL, service: PermanentDeletionService, returned: inout [TrashedItem]
    ) async throws {
        let parent = root.appendingPathComponent("locked-parent-\(UUID().uuidString)", isDirectory: true)
        let file = parent.appendingPathComponent("dix-trash-failure-\(UUID().uuidString).bin")
        let payload = Data("must survive failure \(UUID().uuidString)".utf8)
        try write(payload, to: file)
        let target = try await service.prepare(url: file, scanRoot: root)
        // Make a real rename/unlink failure after preflight, without changing the
        // target identity or modifying any permissions on the user's Trash.
        try check(chflags(parent.path, UInt32(UF_IMMUTABLE)) == 0, "Cannot lock the isolated failure fixture")
        defer { chflags(parent.path, 0) }
        var failed = false
        do {
            _ = try await trash(target, service: service, payload: payload, returned: &returned)
        } catch let error as Failure {
            throw error
        } catch {
            failed = true
        }
        try check(failed, "Trash unexpectedly moved a child out of an immutable parent")
        let actual = try Data(contentsOf: file)
        try check(actual == payload, "A failed Trash operation permanently removed or changed the original")
        try check(chflags(parent.path, 0) == 0, "Cannot unlock the isolated failure fixture")
    }
}
