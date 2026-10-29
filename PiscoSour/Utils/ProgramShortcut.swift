//
//  ProgramShortcut.swift
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

import Foundation
import AppKit
import PiscoSourKit

class ProgramShortcut {
    public static func createShortcut(_ program: Program, app: URL, name: String) async {
        do {
            try await ProgramBundle.create(for: program, at: app, name: name,
                                           identifier: Bundle.appBundleIdentifier + ".shortcut."
                                           + ProgramBundle.sanitized(name))
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch {
            print(error)
        }
    }
}
