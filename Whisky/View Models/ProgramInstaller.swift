//
//  ProgramInstaller.swift
//  Whisky
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import SemanticVersion
import WhiskyKit

/// Installs each Windows program in a bottle of its own, so the user only deals with programs.
/// Bottles are cloned from a ready-made template: on APFS the copy is instant and takes no space until it changes.
enum ProgramInstaller {
    static let templateURL = WhiskyWineInstaller.applicationFolder.appending(path: "BottleTemplate")
    private static let templateStamp = "TemplateWineVersion"

    /// Runs the installer in a new bottle and pins what it adds to the Start Menu (which creates the Mac apps).
    /// Returns the names of the installed programs; empty if the installer added none.
    @MainActor
    static func install(_ installer: URL, bottleVM: BottleVM) async throws -> [String] {
        if let game = try await installClassicGame(installer) {
            return [game]
        }
        let wineVersion = try await Wine.wineVersion()
        try await prepareTemplate(wineVersion: wineVersion)

        let bottleURL = BottleData.defaultBottleDir.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: BottleData.defaultBottleDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: templateURL, to: bottleURL)
        for file in [templateStamp, "Metadata.plist"] {
            try? FileManager.default.removeItem(at: bottleURL.appending(path: file))
        }
        try addWindowsICU(to: bottleURL)

        let bottle = Bottle(bottleUrl: bottleURL, inFlight: true)
        bottle.settings.name = installer.deletingPathExtension().lastPathComponent
        bottle.settings.windowsVersion = .win10
        bottle.settings.wineVersion = SemanticVersion(wineVersion) ?? SemanticVersion(0, 0, 0)
        bottleVM.bottlesList.paths.append(bottleURL)

        do {
            if installer.pathExtension.lowercased() == "iso" {
                try await installFromDisc(installer, bottle: bottle)
            } else {
                try await runInstaller(installer, bottle: bottle)
            }
        } catch {
            bottle.remove(delete: true)
            throw error
        }

        bottle.updateInstalledPrograms()
        let installed = bottle.pinStartMenuPrograms()
        // Nothing new on drive C (e.g. the installer was cancelled): don't leave an empty bottle behind
        if installed.isEmpty && executables(in: bottleURL).isSubset(of: executables(in: templateURL)) {
            bottle.remove(delete: true)
            throw "El instalador se cerró sin instalar nada. ¿Lo cancelaste? Puedes intentarlo de nuevo."
        }
        if let name = installed.first {
            bottle.settings.name = name
        }
        bottleVM.loadBottles()
        return installed
    }

    /// 16-bit Windows programs can't run in Wine on Apple Silicon: install them as ScummVM games if possible
    private static func installClassicGame(_ installer: URL) async throws -> String? {
        guard installer.pathExtension.lowercased() == "iso" else {
            guard ClassicGames.isWin16(installer) else { return nil }
            return try await ClassicGames.install(from: installer.deletingLastPathComponent())
        }

        let volume = try DiscImage.attach(installer)
        defer { DiscImage.detach(volume) }
        // The autorun menu may be 32-bit while the setup it launches is 16-bit (e.g. Sierra discs)
        let setups = [DiscImage.setupProgram(in: volume), volume.appending(path: "SETUP.EXE")].compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard setups.isEmpty || setups.contains(where: ClassicGames.isWin16) else { return nil }
        return try await ClassicGames.install(from: volume)
    }

    /// `start /wait` returns when the installer exits; `wineserver -w` when everything it started has finished
    /// Many installers open the program when they finish, and `wineserver -w` would wait until the user closes it.
    /// So it also stops waiting once the installer's shortcuts are in place and haven't changed for a few seconds.
    private static func runInstaller(_ installer: URL, bottle: Bottle) async throws {
        let before = shortcuts(in: bottle.url)
        try await Wine.runWine(["start", "/wait", "/unix", installer.path(percentEncoded: false)], bottle: bottle)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in try Wine.runWineserverProcess(args: ["-w"], bottle: bottle) { }
            }
            group.addTask {
                try await waitForShortcuts(in: bottle.url, before: before)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Returns once there are new shortcuts that haven't changed for a few seconds
    private static func waitForShortcuts(in bottle: URL, before: [String: Date]) async throws {
        var last = before
        var unchangedSince = Date()
        while true {
            try await Task.sleep(for: .seconds(2))
            let now = shortcuts(in: bottle)
            if now != last {
                last = now
                unchangedSince = Date()
            } else if now != before && Date().timeIntervalSince(unchangedSince) >= 6 {
                return
            }
        }
    }

    /// Start Menu and Desktop shortcuts, with their dates, to notice when an installer adds them
    private static func shortcuts(in bottle: URL) -> [String: Date] {
        var found: [String: Date] = [:]
        let enumerator = FileManager.default.enumerator(at: bottle.appending(path: "drive_c"),
                                                        includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "windows" { enumerator?.skipDescendants() }
            guard url.pathExtension.lowercased() == "lnk" else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            found[url.path] = date ?? .distantPast
        }
        return found
    }

    /// Programs on drive C (outside Windows itself and temporary files), relative to the bottle
    private static func executables(in bottle: URL) -> Set<String> {
        let driveC = bottle.appending(path: "drive_c")
        var found: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: driveC, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if ["windows", "Temp"].contains(url.lastPathComponent) { enumerator?.skipDescendants() }
            if url.pathExtension.lowercased() == "exe" {
                let path = url.path(percentEncoded: false)
                found.insert(String(path.dropFirst(driveC.path(percentEncoded: false).count)))
            }
        }
        return found
    }

    /// Mounts the disc image as CD drive D: and runs its setup, as Windows would from autorun
    private static func installFromDisc(_ iso: URL, bottle: Bottle) async throws {
        let volume = try DiscImage.attach(iso)
        defer { DiscImage.detach(volume) }

        let drive = bottle.url.appending(path: "dosdevices/d:")
        try? FileManager.default.removeItem(at: drive)
        try FileManager.default.createSymbolicLink(at: drive, withDestinationURL: volume)
        defer { try? FileManager.default.removeItem(at: drive) }
        try await Wine.runWine(["reg", "add", "HKLM\\Software\\Wine\\Drives", "/v", "d:", "/d", "cdrom", "/f"],
                               bottle: bottle)

        guard let setup = DiscImage.setupProgram(in: volume) else {
            throw "No se encontró un instalador (setup.exe) en la imagen de disco"
        }
        try await runInstaller(setup, bottle: bottle)
    }

    /// Windows 10 ships ICU and Qt 6 apps (e.g. Tibia) need it; Wine doesn't have it
    private static func addWindowsICU(to bottleURL: URL) throws {
        guard let icu = Bundle.main.url(forResource: "WindowsICU", withExtension: nil) else { return }
        let system32 = bottleURL.appending(path: "drive_c/windows/system32")
        for dll in try FileManager.default.contentsOfDirectory(at: icu, includingPropertiesForKeys: nil)
        where dll.pathExtension == "dll" {
            let target = system32.appending(path: dll.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: dll, to: target)
        }
    }

    /// A clean, initialised Wine prefix; rebuilt when the installed Wine changes
    private static func prepareTemplate(wineVersion: String) async throws {
        let stamp = templateURL.appending(path: templateStamp)
        if (try? String(contentsOf: stamp, encoding: .utf8)) == wineVersion { return }

        try? FileManager.default.removeItem(at: templateURL)
        try FileManager.default.createDirectory(at: templateURL, withIntermediateDirectories: true)
        let template = Bottle(bottleUrl: templateURL)
        try await Wine.changeWinVersion(bottle: template, win: .win10)
        for await _ in try Wine.runWineserverProcess(args: ["-w"], bottle: template) { }
        try wineVersion.write(to: stamp, atomically: true, encoding: .utf8)
    }
}

/// Mounting of .iso images with hdiutil
enum DiscImage {
    static func attach(_ image: URL) throws -> URL {
        let output = try hdiutil(["attach", "-nobrowse", "-readonly", "-plist", image.path(percentEncoded: false)])
        let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw "No se pudo montar la imagen de disco"
        }
        return URL(filePath: mountPoint, directoryHint: .isDirectory)
    }

    static func detach(_ volume: URL) {
        _ = try? hdiutil(["detach", volume.path(percentEncoded: false)])
    }

    /// The program autorun.inf opens, otherwise setup.exe or the only installer at the root of the disc
    static func setupProgram(in volume: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? []
        func file(named name: String) -> URL? {
            files.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
        }

        if let autorun = file(named: "autorun.inf"),
           let text = try? String(contentsOf: autorun, encoding: .isoLatin1),
           let line = text.components(separatedBy: .newlines)
            .first(where: { $0.lowercased().hasPrefix("open=") }) {
            // open=setup.exe /args or open="path\setup.exe"
            let command = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let path = command.hasPrefix("\"")
                ? String(command.dropFirst().prefix { $0 != "\"" })
                : String(command.prefix { $0 != " " })
            let target = volume.appending(path: path.replacingOccurrences(of: "\\", with: "/"))
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) { return target }
        }
        if let setup = file(named: "setup.exe") { return setup }
        let installers = files.filter { ["exe", "msi"].contains($0.pathExtension.lowercased()) }
        return installers.count == 1 ? installers.first : nil
    }

    private static func hdiutil(_ args: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = args
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw "hdiutil \(args.first ?? "") falló" }
        return data
    }
}
