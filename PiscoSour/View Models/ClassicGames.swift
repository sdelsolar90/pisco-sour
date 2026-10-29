//
//  ClassicGames.swift
//  PiscoSour
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
//  Modified for Pisco Sour (https://github.com/sdelsolar90/pisco-sour).
//

import AppKit
import CryptoKit
import PiscoSourKit

struct ClassicGame: Identifiable {
    let folder: URL
    let name: String
    let target: String
    var id: URL { folder }
    var app: URL { ProgramBundle.applicationsFolder.appending(path: "\(name).app") }
}

/// Classic games (Windows 3.1, DOS...) run in ScummVM instead of Wine: their 16-bit code can't run under
/// Rosetta (no LDT support), and ScummVM reimplements their engines natively.
enum ClassicGames {
    static let folder = WineInstaller.applicationFolder.appending(path: "Games")
    /// ScummVM's data files (Resources), from the official release
    private static let scummvmFolder = WineInstaller.libraryFolder.appending(path: "ScummVM")
    /// The program and its libraries, apart from the data and not laid out like an app ("bin", not "MacOS"):
    /// macOS doesn't let Pisco Sour write there otherwise (App Management)
    private static let programFolder = WineInstaller.libraryFolder.appending(path: "ScummVMProgram")
    private static let scummvm = programFolder.appending(path: "bin/scummvm")
    private static let downloadURL = URL(string: "https://downloads.scummvm.org/frs/scummvm/2026.4.0/"
                                         + "scummvm-2026.4.0-macosx.dmg")
    private static let downloadSHA256 = "5614527fa57ffce14773c69923b96eeb7b1b135bcd96bfe74640ca341cad4598"

    /// 16-bit Windows programs are "NE" executables; 32 and 64-bit ones are "PE"
    static func isWin16(_ exe: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: exe),
              let header = try? handle.read(upToCount: 64), header.count == 64,
              header.prefix(2) == Data("MZ".utf8) else { return false }
        let offset = header[0x3C..<0x40].reversed().reduce(0) { $0 << 8 | Int($1) }
        try? handle.seek(toOffset: UInt64(offset))
        return (try? handle.read(upToCount: 2)) == Data("NE".utf8)
    }

    static func load() -> [ClassicGame] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { game in
            guard let info = NSDictionary(contentsOf: game.appending(path: "Game.plist")),
                  let name = info["name"] as? String, let target = info["target"] as? String else { return nil }
            return ClassicGame(folder: game, name: name, target: target)
        }
    }

    /// Copies the game files and makes its Mac app. Returns the game name
    static func install(from source: URL) async throws -> String {
        try await installScummVM()
        guard let (target, name) = try await detect(in: source) else {
            throw "Este programa es de Windows 3.1 (16 bits) y no es un juego que Pisco Sour sepa ejecutar."
        }

        let game = ClassicGame(folder: folder.appending(path: UUID().uuidString), name: name, target: target)
        try FileManager.default.createDirectory(at: game.folder, withIntermediateDirectories: true)
        try await Task.detached {
            try FileManager.default.copyItem(at: source, to: game.folder.appending(path: "Data"))
        }.value
        NSDictionary(dictionary: ["name": name, "target": target])
            .write(to: game.folder.appending(path: "Game.plist"), atomically: true)
        try makeApp(for: game, icon: icon(in: source))
        return name
    }

    /// Brings games installed by an older Pisco Sour up to date
    static func update(_ games: [ClassicGame]) {
        var newBinary = false
        do {
            newBinary = try installPiscoBinary()
        } catch {
            print("Failed to install Pisco Sour's ScummVM: \(error)")
        }
        for game in games {
            let config = try? String(contentsOf: game.folder.appending(path: "scummvm.ini"), encoding: .utf8)
            let binary = game.app.appending(path: "Contents/MacOS").appending(path: game.name)
            if newBinary || config?.contains("[game]") != true
                || !FileManager.default.fileExists(atPath: binary.path(percentEncoded: false)) {
                try? refresh(game)
            }
        }
    }

    /// Rebuilds the game's app and settings, keeping its icon (or taking it from the game files again)
    static func refresh(_ game: ClassicGame) throws {
        let icon = NSImage(contentsOf: game.app.appending(path: "Contents/Resources/AppIcon.icns"))
            ?? icon(in: game.folder.appending(path: "Data"))
        try makeApp(for: game, icon: icon)
    }

    static func uninstall(_ game: ClassicGame) {
        try? FileManager.default.removeItem(at: game.app)
        try? FileManager.default.removeItem(at: game.folder)
    }

    private static func installScummVM() async throws {
        guard !FileManager.default.fileExists(atPath: scummvm.path(percentEncoded: false)) else { return }
        guard let downloadURL else { return }
        let (download, _) = try await URLSession.shared.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: download) }
        let hash = SHA256.hash(data: try Data(contentsOf: download)).map { String(format: "%02x", $0) }.joined()
        guard hash == downloadSHA256 else { throw "La descarga de ScummVM está dañada" }

        let volume = try DiscImage.attach(download)
        defer { DiscImage.detach(volume) }
        // The official release brings the data files; the program comes from Pisco Sour when it ships one
        let official = volume.appending(path: "ScummVM.app/Contents")
        try? FileManager.default.removeItem(at: scummvmFolder)
        try FileManager.default.createDirectory(at: scummvmFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: official.appending(path: "Resources"),
                                         to: scummvmFolder.appending(path: "Resources"))
        if try !installPiscoBinary() {
            try FileManager.default.createDirectory(at: scummvm.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: official.appending(path: "MacOS/scummvm"), to: scummvm)
            try FileManager.default.copyItem(at: official.appending(path: "Frameworks"),
                                             to: programFolder.appending(path: "Frameworks"))
        }
    }

    /// Swaps in the scummvm Pisco Sour ships (scripts/build-scummvm.sh: no ScummVM splash screen) and its libraries.
    /// Returns true if it changed, so the game apps get the new binary too
    @discardableResult
    private static func installPiscoBinary() throws -> Bool {
        let resources = scummvmFolder.appending(path: "Resources")
        guard let bundled = Bundle.main.url(forResource: "ScummVM", withExtension: nil),
              FileManager.default.fileExists(atPath: resources.path(percentEncoded: false)) else { return false }
        let binary = bundled.appending(path: "scummvm")
        let attributes = try FileManager.default.attributesOfItem(atPath: binary.path(percentEncoded: false))
        let build = "\(attributes[.size] ?? 0) \(attributes[.modificationDate] ?? "")"
        let stamp = programFolder.appending(path: "PiscoSourBuild")
        guard (try? String(contentsOf: stamp, encoding: .utf8)) != build else { return false }

        let frameworks = programFolder.appending(path: "Frameworks")
        try? FileManager.default.removeItem(at: programFolder)
        try FileManager.default.createDirectory(at: scummvm.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: scummvm)
        try FileManager.default.copyItem(at: bundled.appending(path: "libs"), to: frameworks.appending(path: "libs"))
        try build.write(to: stamp, atomically: true, encoding: .utf8)
        return true
    }

    /// ScummVM's game id and the game name (its description without the "(Windows/English)" part)
    private static func detect(in source: URL) async throws -> (String, String)? {
        let output = try await Task.detached {
            try run(scummvm, ["--detect", "--path=\(source.path(percentEncoded: false))"])
        }.value
        for line in output.components(separatedBy: .newlines) {
            let columns = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard columns.count >= 2, columns[0].contains(":"), !columns[0].hasPrefix("-") else { continue }
            let name = columns[1].components(separatedBy: " (").first ?? columns[1]
            return (columns[0], name.replacingOccurrences(of: "/", with: "-"))
        }
        return nil
    }

    /// The game's own .ico, if the disc has one
    private static func icon(in source: URL) -> NSImage? {
        let files = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "ico" }.lazy.compactMap { NSImage(contentsOf: $0) }.first
    }

    /// Like the Wine programs: a copy of the scummvm binary inside the game's bundle, so the Dock shows the game
    private static func makeApp(for game: ClassicGame, icon: NSImage?) throws {
        let contents = game.app.appending(path: "Contents")
        let macos = contents.appending(path: "MacOS")
        let resources = contents.appending(path: "Resources")
        try? FileManager.default.removeItem(at: game.app)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        // Named after the game, so Activity Monitor shows the game too
        let binary = macos.appending(path: game.name)
        try FileManager.default.copyItem(at: scummvm, to: binary)
        _ = try run(URL(filePath: "/usr/bin/codesign"), ["-f", "-s", "-", binary.path])
        try FileManager.default.createSymbolicLink(at: contents.appending(path: "Frameworks"),
                                                   withDestinationURL: programFolder.appending(path: "Frameworks"))
        let scummvmResources = scummvmFolder.appending(path: "Resources")
        for file in try FileManager.default.contentsOfDirectory(atPath: scummvmResources.path)
        where file != "scummvm.docktileplugin" {
            try FileManager.default.createSymbolicLink(at: resources.appending(path: file),
                                                       withDestinationURL: scummvmResources.appending(path: file))
        }
        if let icon {
            try ProgramBundle.writeIcon(icon, to: resources.appending(path: "AppIcon.icns"))
        }

        try writeConfig(for: game)
        let script = """
        #!/bin/bash
        DIR="$(cd "$(dirname "$0")" && pwd)"
        exec "$DIR/\(game.name)" --config="\(game.folder.path(percentEncoded: false))/scummvm.ini" game
        """
        try script.write(to: macos.appending(path: "launch"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: macos.appending(path: "launch").path)

        let identifier = Bundle.appBundleIdentifier + ".game."
            + ProgramBundle.sanitized(game.folder.lastPathComponent)
        let info: NSDictionary = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": identifier,
            "CFBundleName": game.name,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": icon == nil ? "scummvm" : "AppIcon",
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": true,
            "LSApplicationCategoryType": "public.app-category.games"
        ]
        info.write(to: contents.appending(path: "Info.plist"), atomically: true)
        LSRegisterURL(game.app as CFURL, true)
    }

    /// Settings and saved games stay with the game, apart from a ScummVM the user may have. Skips ScummVM's
    /// first-run questions and titles the window with the game name, so it looks like the game's own app
    private static func writeConfig(for game: ClassicGame) throws {
        let folder = game.folder.path(percentEncoded: false)
        try FileManager.default.createDirectory(at: game.folder.appending(path: "Saves"),
                                                withIntermediateDirectories: true)
        let ids = game.target.split(separator: ":").map(String.init)
        let config = """
        [scummvm]
        updates_check=0
        gui_return_to_launcher_at_exit=false
        confirm_exit=false

        [game]
        engineid=\(ids.first ?? "")
        gameid=\(ids.last ?? "")
        description=\(game.name)
        path=\(folder)/Data
        savepath=\(folder)/Saves

        """
        try config.write(to: game.folder.appending(path: "scummvm.ini"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private static func run(_ executable: URL, _ args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
