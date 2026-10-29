//
//  WineInstaller.swift
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
import CryptoKit
import SemanticVersion

public class WineInstaller {
    /// The Pisco Sour data folder
    public static let applicationFolder = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appending(path: Bundle.appBundleIdentifier)

    /// The folder of all the libfrary files
    public static let libraryFolder = applicationFolder.appending(path: "Libraries")

    /// URL to the installed `wine` `bin` directory
    public static let binFolder: URL = libraryFolder.appending(path: "Wine").appending(path: "bin")

    /// WhiskyWine is no longer served; use Gcenx's upstream Wine build instead
    public static let wineDownloadURL = URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/"
                                            + "11.0_1/wine-stable-11.0_1-osx64.tar.xz")
    private static let downloadedWineVersion = SemanticVersion(11, 0, 1)
    private static let downloadSHA256 = "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"
    private static let versionPlist = libraryFolder.appending(path: "WhiskyWineVersion").appendingPathExtension("plist")

    public static func isWineInstalled() -> Bool {
        return installedWineVersion() != nil
    }

    public static func install(from: URL) {
        do {
            defer { try? FileManager.default.removeItem(at: from) }
            let hash = SHA256.hash(data: try Data(contentsOf: from)).map { String(format: "%02x", $0) }.joined()
            guard hash == downloadSHA256 else { throw "The Wine download is damaged or not the expected one" }

            // Only Wine is replaced: the same folder holds the bottles, games and ScummVM
            try FileManager.default.createDirectory(at: applicationFolder, withIntermediateDirectories: true)
            let wineFiles = [libraryFolder.appending(path: "Wine"), versionPlist,
                             applicationFolder.appending(path: "Wine Stable.app")]
            for old in wineFiles {
                try? FileManager.default.removeItem(at: old)
            }
            try Tar.untar(tarBall: from, toURL: applicationFolder)
            try moveDownloadedWine()
        } catch {
            print("Failed to install Wine: \(error)")
        }
    }

    /// Lays out Gcenx's "Wine Stable.app" the way WhiskyWine was: Libraries/Wine plus a version plist
    private static func moveDownloadedWine() throws {
        let wineApp = applicationFolder.appending(path: "Wine Stable.app")
        guard FileManager.default.fileExists(atPath: wineApp.path(percentEncoded: false)) else { return }

        try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: wineApp.appending(path: "Contents/Resources/wine"),
                                         to: libraryFolder.appending(path: "Wine"))
        try FileManager.default.removeItem(at: wineApp)
        let wine64 = binFolder.appending(path: "wine64").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: wine64, withDestinationPath: "wine")

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(WineVersionInfo(version: downloadedWineVersion))
            .write(to: versionPlist)
    }

    public static func uninstall() {
        do {
            // Libraries also holds ScummVM, which classic games need
            try FileManager.default.removeItem(at: libraryFolder.appending(path: "Wine"))
            try FileManager.default.removeItem(at: versionPlist)
        } catch {
            print("Failed to uninstall Wine: \(error)")
        }
    }

    /// Whisky's version feed isn't Pisco Sour's, and an update reinstalls Wine: no checks until it has its own
    public static func shouldUpdateWine() async -> (Bool, SemanticVersion) {
        return (false, SemanticVersion(0, 0, 0))
    }

    public static func installedWineVersion() -> SemanticVersion? {
        do {
            let versionPlist = libraryFolder
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")

            let decoder = PropertyListDecoder()
            let data = try Data(contentsOf: versionPlist)
            let info = try decoder.decode(WineVersionInfo.self, from: data)
            return info.version
        } catch {
            print(error)
            return nil
        }
    }
}

struct WineVersionInfo: Codable {
    var version: SemanticVersion = SemanticVersion(1, 0, 0)
}
