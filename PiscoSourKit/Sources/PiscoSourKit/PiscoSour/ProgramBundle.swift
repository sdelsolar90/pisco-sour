//
//  ProgramBundle.swift
//  PiscoSourKit
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

import Foundation
import AppKit
import QuickLookThumbnailing

/// A macOS app bundle that runs a Windows program as itself: own name and icon in the Dock,
/// Cmd+Tab and menu bar, instead of showing up as "wine".
public enum ProgramBundle {
    /// Folder for the bundles of programs that are not pinned (uninstallers, tools...)
    public static let launchersFolder = WineInstaller.applicationFolder.appending(path: "Launchers")
    /// Pinned programs get their app here, so they show up in Launchpad, Spotlight and Finder like any Mac app
    public static let applicationsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Applications").appending(path: "Pisco Sour")

    /// Bundle used to run the program: created the first time, reused afterwards (only the launch
    /// script is refreshed, so it follows the program settings)
    public static func launcher(for program: Program) async throws -> URL {
        let identifier = identifier(for: program)
        let name = displayName(for: program)
        let app = appURL(for: program, name: name, identifier: identifier)
        let existing = bundles(in: [applicationsFolder, launchersFolder]) { $0["CFBundleIdentifier"] == identifier }

        if existing == [app] && isUsable(app, name: name) {
            try writeLaunchScript(for: program, macos: app.appending(path: "Contents").appending(path: "MacOS"))
            return app
        }
        // Renamed, pinned/unpinned or broken (e.g. Wine was reinstalled): build it again
        existing.forEach { try? FileManager.default.removeItem(at: $0) }
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try await create(for: program, at: app, name: name, identifier: identifier)
        return app
    }

    /// Removes the program's app (when it is unpinned)
    public static func removeApp(for program: Program) {
        let identifier = identifier(for: program)
        bundles(in: [applicationsFolder]) { $0["CFBundleIdentifier"] == identifier }
            .forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Removes the apps of every program in a bottle (when the bottle is removed)
    public static func removeApps(bottle: URL) {
        bundles(in: [applicationsFolder, launchersFolder]) { $0["WhiskyBottle"] == bottle.path(percentEncoded: false) }
            .forEach { try? FileManager.default.removeItem(at: $0) }
    }

    public static func create(for program: Program, at app: URL, name: String, identifier: String) async throws {
        let contents = app.appending(path: "Contents")
        let macos = contents.appending(path: "MacOS")
        if FileManager.default.fileExists(atPath: app.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: app)
        }
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try installLoader(contents: contents, name: name, identifier: identifier)
        try writeLaunchScript(for: program, macos: macos)
        try writeInfoPlist(contents: contents, name: name, identifier: identifier,
                           bottle: program.bottle.url.path(percentEncoded: false))

        // Wine binds Quit to Cmd+Option+Q and passes Cmd+Q to the program as Alt+Q.
        // Make Cmd+Q quit, like any Mac app (menu title is "Quit <name>", or "Salir <name>" in Spanish)
        UserDefaults(suiteName: identifier)?.set(["Quit \(name)": "@q", "Salir \(name)": "@q"],
                                                 forKey: "NSUserKeyEquivalents")

        // Launchpad and the Dock read the icon from Contents/Resources (CFBundleIconFile), not a Finder custom icon
        var icon = program.peFile?.bestIcon()
        if icon == nil {
            let request = QLThumbnailGenerator.Request(fileAt: program.url,
                                                       size: CGSize(width: 512, height: 512),
                                                       scale: 2.0,
                                                       representationTypes: .thumbnail)
            icon = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        if let icon {
            try writeIcon(icon, to: contents.appending(path: "Resources").appending(path: "AppIcon.icns"))
        }
        // Tell Launch Services about the (re)built bundle, or Launchpad keeps a cached blank icon
        LSRegisterURL(app as CFURL, true)
    }

    /// Builds a full .icns (16 to 1024 px) with iconutil: Launchpad shows a blank icon if the size it wants is missing
    public static func writeIcon(_ icon: NSImage, to url: URL) throws {
        let iconset = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }

        for size in [16, 32, 128, 256, 512] {
            try writePNG(icon, pixels: size, to: iconset.appending(path: "icon_\(size)x\(size).png"))
            try writePNG(icon, pixels: size * 2, to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", "-o", url.path(percentEncoded: false), iconset.path(percentEncoded: false)]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0 else { throw "Cannot write icon file" }
    }

    /// Draws at exact pixels (NSImage sizes are points, doubled on Retina screens)
    private static func writePNG(_ icon: NSImage, pixels: Int, to url: URL) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw "Cannot draw icon" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw "Cannot draw icon" }
        try png.write(to: url)
    }

    private static func writeLaunchScript(for program: Program, macos: URL) throws {
        let script = """
        #!/bin/bash
        \(program.generateBundleRunScript())
        """
        let scriptUrl = macos.appending(path: "launch")
        try script.write(to: scriptUrl,
                         atomically: false,
                         encoding: .utf8)

        // Make shell script runable
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: scriptUrl.path(percentEncoded: false))
    }

    private static func identifier(for program: Program) -> String {
        let bottle = sanitized(program.bottle.url.lastPathComponent)
        let path = sanitized(program.url.path(percentEncoded: false)
            .replacingOccurrences(of: program.bottle.url.path(percentEncoded: false), with: ""))
        return "\(Bundle.appBundleIdentifier).launcher.\(bottle).\(path.suffix(60))"
    }

    /// The pin name (from the Start Menu shortcut) if pinned, otherwise the file name
    private static func displayName(for program: Program) -> String {
        let pin = program.bottle.settings.pins.first { $0.url == program.url }
        let name = pin?.name ?? program.name.replacingOccurrences(of: ".exe", with: "")
        return name.replacingOccurrences(of: "/", with: "-")
    }

    /// The Dock and Launchpad show the bundle's file name, so it carries the program name
    private static func appURL(for program: Program, name: String, identifier: String) -> URL {
        guard program.pinned else {
            return launchersFolder.appending(path: identifier).appending(path: "\(name).app")
        }
        let app = applicationsFolder.appending(path: "\(name).app")
        let owner = infoDictionary(of: app)?["CFBundleIdentifier"]
        // Same name used by a program in another bottle
        if let owner, owner != identifier {
            return applicationsFolder.appending(path: "\(name) (\(program.bottle.settings.name)).app")
        }
        return app
    }

    private static func isUsable(_ app: URL, name: String) -> Bool {
        let ntdll = app.appending(path: "Contents").appending(path: "MacOS").appending(path: "ntdll.so")
        let icon = app.appending(path: "Contents").appending(path: "Resources").appending(path: "AppIcon.icns")
        return infoDictionary(of: app)?["CFBundleName"] == name
            && FileManager.default.fileExists(atPath: ntdll.path(percentEncoded: false))
            && FileManager.default.fileExists(atPath: icon.path(percentEncoded: false))
    }

    private static func infoDictionary(of app: URL) -> [String: String]? {
        let plist = app.appending(path: "Contents").appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info.compactMapValues { $0 as? String }
    }

    /// Apps made by Pisco Sour in these folders (Launchers keeps each app inside its own subfolder)
    private static func bundles(in folders: [URL], where matches: ([String: String]) -> Bool) -> [URL] {
        var apps: [URL] = []
        for folder in folders {
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == "app", let info = infoDictionary(of: url), matches(info) {
                    apps.append(url.standardizedFileURL)
                }
            }
        }
        return apps
    }

    public static func sanitized(_ name: String) -> String {
        name.filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    private static func writeInfoPlist(contents: URL, name: String, identifier: String, bottle: String) throws {
        // Create Info.plist (set category for Game mode)
        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>launch</string>
            <key>CFBundleIdentifier</key>
            <string>\(identifier)</string>
            <key>CFBundleName</key>
            <string>\(xmlEscaped(name))</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>WhiskyBottle</key>
            <string>\(xmlEscaped(bottle))</string>
            <key>NSPrincipalClass</key>
            <string>WineApplication</string>
            <key>LSUIElement</key>
            <string>1</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
            <key>CFBundleSupportedPlatforms</key>
            <array>
                <string>MacOSX</string>
            </array>
            <key>LSMinimumSystemVersion</key>
            <string>14.0</string>
            <key>LSApplicationCategoryType</key>
            <string>public.app-category.games</string>
        </dict>
        </plist>
        """
        try info.write(to: contents.appending(path: "Info")
                                   .appendingPathExtension("plist"),
                       atomically: false,
                       encoding: .utf8)
    }

    /// Puts a copy of the Wine loader inside the bundle so the running program belongs to it
    /// (own name in the Dock and menu bar instead of "wine"). Everything else links to the installed Wine.
    private static func installLoader(contents: URL, name: String, identifier: String) throws {
        let wineLib = WineInstaller.libraryFolder.appending(path: "Wine").appending(path: "lib")
            .appending(path: "wine")
        let unixLib = wineLib.appending(path: "x86_64-unix")
        let macos = contents.appending(path: "MacOS")
        let fileManager = FileManager.default

        for file in try fileManager.contentsOfDirectory(atPath: unixLib.path(percentEncoded: false)) {
            let source = unixLib.appending(path: file)
            if file == "wine" {
                try fileManager.copyItem(at: source, to: macos.appending(path: file))
            } else {
                try fileManager.createSymbolicLink(at: macos.appending(path: file), withDestinationURL: source)
            }
        }
        // The loader looks for the PE libraries next to its own folder
        for dir in ["x86_64-windows", "i386-windows"] {
            try fileManager.createSymbolicLink(at: contents.appending(path: dir),
                                               withDestinationURL: wineLib.appending(path: dir))
        }

        let loader = macos.appending(path: "wine")
        try replaceEmbeddedInfo(of: loader, name: name, identifier: identifier)

        // Patching broke the signature; sign again ad hoc
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["-f", "-s", "-", loader.path(percentEncoded: false)]
        try codesign.run()
        codesign.waitUntilExit()
    }

    /// The loader embeds Wine's Info.plist, which would win over the bundle's: replace it in place
    private static func replaceEmbeddedInfo(of loader: URL, name: String, identifier: String) throws {
        var data = try Data(contentsOf: loader)
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex) else {
            throw "Embedded Info.plist not found in Wine loader"
        }
        var plist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>wine</string>
        <key>CFBundleIdentifier</key><string>\(identifier)</string>
        <key>CFBundleName</key><string>\(xmlEscaped(name))</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>NSPrincipalClass</key><string>WineApplication</string>
        <key>LSUIElement</key><string>1</string>
        </dict></plist>
        """.utf8)
        let size = end.upperBound - start.lowerBound
        guard plist.count <= size else { throw "Program name too long for the Wine loader" }
        plist.append(Data(repeating: UInt8(ascii: " "), count: size - plist.count))
        data.replaceSubrange(start.lowerBound..<end.upperBound, with: plist)
        try data.write(to: loader)
    }

    private static func xmlEscaped(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
