//
//  ProgramsHomeView.swift
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

import SwiftUI
import UniformTypeIdentifiers
import PiscoSourKit

/// Main screen: the installed programs of every bottle. Bottles stay behind the scenes (one per program).
struct ProgramsHomeView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @State private var path = NavigationPath()
    @State private var installing: String?
    @State private var games: [ClassicGame] = []

    private let gridLayout = [GridItem(.adaptive(minimum: 100, maximum: .infinity))]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if installedPrograms.isEmpty && games.isEmpty && installing == nil {
                    ContentUnavailableView {
                        Label("Sin programas", systemImage: "square.dashed")
                    } description: {
                        Text("Instala un programa de Windows (.exe, .msi o .iso) o arrástralo aquí. "
                             + "Aparecerá aquí y en las apps de tu Mac.")
                    } actions: {
                        Button("Instalar programa…") { chooseInstaller() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridLayout, alignment: .center) {
                            ForEach(installedPrograms, id: \.id) { item in
                                PinView(bottle: item.bottle, program: item.program, pin: item.pin, path: $path) {
                                    uninstall(item.program, bottle: item.bottle, name: item.pin.name)
                                }
                            }
                            ForEach(games) { game in
                                GameView(game: game) { uninstall(game) }
                            }
                            if let installing {
                                VStack {
                                    ProgressView()
                                        .frame(width: 45, height: 45)
                                    Spacer()
                                    Text("Instalando \(installing)…")
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2, reservesSpace: true)
                                }
                                .frame(width: 90, height: 90)
                                .padding(10)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationDestination(for: Program.self) { program in
                ProgramView(program: program)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        chooseInstaller()
                    } label: {
                        Label("Instalar programa…", systemImage: "plus")
                    }
                    .help("Instalar programa…")
                    .disabled(installing != nil)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard installing == nil, let url = urls.first,
                  ["exe", "msi", "iso"].contains(url.pathExtension.lowercased()) else { return false }
            install(url)
            return true
        }
        .task {
            reload()
        }
    }

    // swiftlint:disable:next large_tuple
    private var installedPrograms: [(bottle: Bottle, pin: PinnedProgram, program: Program, id: String)] {
        bottleVM.bottles
            .filter { $0.isAvailable }
            .flatMap { bottle in
                bottle.pinnedPrograms.map { (bottle, $0.pin, $0.program, $0.id) }
            }
            .sorted { $0.pin.name.localizedCaseInsensitiveCompare($1.pin.name) == .orderedAscending }
    }

    private func reload() {
        games = ClassicGames.load().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        ClassicGames.update(games)
        bottleVM.loadBottles()
        for bottle in bottleVM.bottles where bottle.isAvailable {
            bottle.updateInstalledPrograms()
            bottle.pinStartMenuPrograms()
        }
        if WhiskyMigration.needsAppRebuild {
            WhiskyMigration.needsAppRebuild = false
            for item in installedPrograms {
                Task { _ = try? await ProgramBundle.launcher(for: item.program) }
            }
            games.forEach { try? ClassicGames.refresh($0) }
        }
    }

    private func chooseInstaller() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.exe, UTType(exportedAs: "com.microsoft.msi-installer")]
            + [UTType(filenameExtension: "iso")].compactMap { $0 }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        panel.begin { result in
            if result == .OK, let url = panel.urls.first {
                install(url)
            }
        }
    }

    private func install(_ installer: URL) {
        installing = installer.deletingPathExtension().lastPathComponent
        Task { @MainActor in
            do {
                let installed = try await ProgramInstaller.install(installer, bottleVM: bottleVM)
                if installed.isEmpty {
                    showAlert("No se encontró ningún programa instalado",
                              "El instalador terminó sin crear accesos en el menú Inicio. "
                              + "Puedes ver lo instalado en la vista de botellas.")
                }
            } catch {
                showAlert("No se pudo instalar", error.localizedDescription)
            }
            installing = nil
            reload()
        }
    }

    /// Deletes the program's bottle when it only holds this program; otherwise just unpins it
    private func uninstall(_ program: Program, bottle: Bottle, name: String) {
        let deletesBottle = bottle.settings.pins.count <= 1
        let alert = NSAlert()
        alert.messageText = "¿Desinstalar \(name)?"
        alert.informativeText = deletesBottle
            ? "Se borrarán el programa, sus datos y su app del Mac."
            : "Se quitará de la lista y de las apps del Mac. Sus archivos siguen en la botella "
              + "\"\(bottle.settings.name)\", que comparte con otros programas."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Desinstalar")
        alert.addButton(withTitle: String(localized: "button.removeAlert.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if deletesBottle {
            bottle.remove(delete: true)
        } else {
            program.pinned = false
        }
        reload()
    }

    private func uninstall(_ game: ClassicGame) {
        let alert = NSAlert()
        alert.messageText = "¿Desinstalar \(game.name)?"
        alert.informativeText = "Se borrarán el juego, sus partidas guardadas y su app del Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Desinstalar")
        alert.addButton(withTitle: String(localized: "button.removeAlert.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ClassicGames.uninstall(game)
        reload()
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// A ScummVM game: same look as a program's pin, opens its Mac app
struct GameView: View {
    let game: ClassicGame
    var onUninstall: () -> Void

    var body: some View {
        VStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: game.app.path(percentEncoded: false)))
                .resizable()
                .frame(width: 45, height: 45)
            Spacer()
            Text(game.name)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(width: 90, height: 90)
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSWorkspace.shared.openApplication(at: game.app, configuration: .init())
        }
        .contextMenu {
            Button("button.showInFinder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([game.app])
            }
            .labelStyle(.titleAndIcon)
            Divider()
            Button("Desinstalar…", systemImage: "trash", role: .destructive) {
                onUninstall()
            }
            .labelStyle(.titleAndIcon)
        }
    }
}
