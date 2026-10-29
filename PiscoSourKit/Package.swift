// swift-tools-version: 5.9
//
//  PortableExecutable.swift
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

import PackageDescription

let package = Package(
    name: "PiscoSourKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PiscoSourKit",
            targets: ["PiscoSourKit"]
        )
    ],
    dependencies: [
      .package(url: "git@github.com:SwiftPackageIndex/SemanticVersion.git", from: "0.3.0")
    ],
    targets: [
        .target(
            name: "PiscoSourKit",
            dependencies: ["SemanticVersion"]
        )
    ],
    swiftLanguageVersions: [.version("6")]
)
