//
//  Wine+Bundle.swift
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

extension Wine {
    /// Script body for an app bundle that carries its own copy of the loader at `Contents/MacOS/wine`.
    /// Runs the program in the bundle's process (no `start`) so macOS shows the bundle's name and icon.
    public static func generateBundleRunScript(
        at url: URL, bottle: Bottle, args: String, environment: [String: String]
    ) -> String {
        var script = "DIR=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n"
        script += "cd \(url.deletingLastPathComponent().esc)\n"
        let env = constructWineEnvironment(for: bottle, environment: environment)
        for environment in env {
            script += "export \(environment.key)=\"\(environment.value)\"\n"
        }
        // Wine re-executes its loader; keep it inside the bundle
        script += "export WINELOADER=\"$DIR/wine\"\n"
        script += "exec \"$DIR/wine\" \(url.esc) \(args)\n"

        return script
    }
}
