//
//  WhiskyMigration.swift
//  WhiskyKit
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

/// The first Pisco Sour builds used Whisky's identifier (com.isaacmarovitz.Whisky).
/// Moves that data (Wine, bottles, games, settings) to Pisco Sour's own folders, once.
public enum WhiskyMigration {
    static let oldIdentifier = "com.isaacmarovitz.Whisky"
    private static let rebuildKey = "rebuildAppsAfterMigration"

    /// The program and game apps still point to the old folders: the programs screen makes them again
    public static var needsAppRebuild: Bool {
        get { UserDefaults.standard.bool(forKey: rebuildKey) }
        set { UserDefaults.standard.set(newValue, forKey: rebuildKey) }
    }

    public static func migrateIfNeeded() {
        let fileManager = FileManager.default
        let oldSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: oldIdentifier)
        guard Bundle.whiskyBundleIdentifier != oldIdentifier,
              fileManager.fileExists(atPath: oldSupport.path(percentEncoded: false)),
              !fileManager.fileExists(atPath: WhiskyWineInstaller.applicationFolder.path(percentEncoded: false))
        else { return }

        do {
            try fileManager.moveItem(at: oldSupport, to: WhiskyWineInstaller.applicationFolder)
            // Apps of programs that aren't pinned are made again when they run
            try? fileManager.removeItem(at: ProgramBundle.launchersFolder)
            try moveBottles()
            migrateSettings()
            removeOldApps()
            needsAppRebuild = true
        } catch {
            print("Failed to migrate Whisky data: \(error)")
        }
    }

    /// Whisky kept bottles in ~/Library/Containers; their saved paths (pins, bottle list) are rewritten
    private static func moveBottles() throws {
        let fileManager = FileManager.default
        let oldContainer = fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Containers")
            .appending(path: oldIdentifier)
        let oldBottles = oldContainer.appending(path: "Bottles")
        let newBottles = BottleData.defaultBottleDir
        try fileManager.createDirectory(at: newBottles, withIntermediateDirectories: true)

        for bottle in (try? fileManager.contentsOfDirectory(at: oldBottles, includingPropertiesForKeys: nil)) ?? [] {
            try fileManager.moveItem(at: bottle, to: newBottles.appending(path: bottle.lastPathComponent))
        }
        let oldEntries = oldContainer.appending(path: "BottleVM.plist")
        if fileManager.fileExists(atPath: oldEntries.path(percentEncoded: false)) {
            try fileManager.moveItem(at: oldEntries, to: BottleData.bottleEntriesDir)
        }

        let bottles = (try? fileManager.contentsOfDirectory(at: newBottles, includingPropertiesForKeys: nil)) ?? []
        for file in [BottleData.bottleEntriesDir] + bottles.map({ $0.appending(path: "Metadata.plist") }) {
            guard var text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // URLs are saved percent-encoded ("Application%20Support"), plain paths are not
            text = text.replacingOccurrences(of: oldBottles.absoluteString, with: newBottles.absoluteString)
                .replacingOccurrences(of: oldBottles.path(percentEncoded: false),
                                      with: newBottles.path(percentEncoded: false))
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Keeps the user's settings, except the default bottle folder, which pointed to the old one
    private static func migrateSettings() {
        guard var settings = UserDefaults.standard.persistentDomain(forName: oldIdentifier) else { return }
        settings.removeValue(forKey: "defaultBottleLocation")
        UserDefaults.standard.setPersistentDomain(settings, forName: Bundle.whiskyBundleIdentifier)
    }

    private static func removeOldApps() {
        let apps = (try? FileManager.default.contentsOfDirectory(at: ProgramBundle.applicationsFolder,
                                                                 includingPropertiesForKeys: nil)) ?? []
        for app in apps where app.pathExtension == "app" {
            let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
            if (info?["CFBundleIdentifier"] as? String)?.hasPrefix(oldIdentifier + ".") == true {
                try? FileManager.default.removeItem(at: app)
            }
        }
    }
}
