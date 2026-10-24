//
//  ConnectorsView.swift
//  ModelCraft
//

import SwiftUI

struct ConnectorsView: View {

    @State private var applicationURLs: [Connector: URL] = [:]
    @State private var installedConnectors: Set<Connector> = []
    @State private var installingConnectors: Set<Connector> = []
    @State private var failure: ConnectorFailure?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Connector.allCases) { connector in
                    ConnectorCard(
                        connector: connector,
                        state: state(of: connector),
                        onInstall: { install(connector) },
                        onUninstall: { uninstall(connector) })
                }
            }
            .padding()
        }
        .onAppear(perform: refresh)
        // An app downloaded from its releases page appears once the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .alert(
            failure?.title ?? "",
            isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private func state(of connector: Connector) -> ConnectorCard.InstallState {
        if installingConnectors.contains(connector) { return .installing }
        if installedConnectors.contains(connector) { return .installed }
        return applicationURLs[connector] == nil ? .applicationMissing : .notInstalled
    }

    private func refresh() {
        applicationURLs = Dictionary(uniqueKeysWithValues: Connector.allCases.compactMap { connector in
            connector.applicationURL.map { (connector, $0) }
        })
        installedConnectors = Set(Connector.allCases.filter(ConnectorTool.isInstalled))
    }

    private func install(_ connector: Connector) {
        installingConnectors.insert(connector)
        Task {
            defer { installingConnectors.remove(connector) }
            do {
                try await ConnectorTool.install(connector)
                installedConnectors.insert(connector)
            } catch {
                failure = ConnectorFailure(
                    title: String(localized: "Couldn't Install \(connector.name)"),
                    message: error.localizedDescription)
            }
        }
    }

    private func uninstall(_ connector: Connector) {
        do {
            try ConnectorTool.uninstall(connector)
            installedConnectors.remove(connector)
        } catch {
            failure = ConnectorFailure(
                title: String(localized: "Couldn't Uninstall \(connector.name)"),
                message: error.localizedDescription)
        }
    }
}

private struct ConnectorFailure {
    let title: String
    let message: String
}

private struct ConnectorCard: View {

    enum InstallState {
        case applicationMissing
        case notInstalled
        case installing
        case installed
    }

    let connector: Connector
    let state: InstallState
    let onInstall: () -> Void
    let onUninstall: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            ConnectorIcon(name: connector.iconName)

            VStack(alignment: .leading, spacing: 4) {
                Text(connector.name)
                    .font(.title3)
                    .fontDesign(.rounded)
                    .fontWeight(.semibold)
                Text(connector.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            InstallAction()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle().fill(.surface))
    }

    @ViewBuilder
    private func InstallAction() -> some View {
        switch state {
        case .applicationMissing:
            Button("Get \(connector.name)") {
                openURL(connector.releasesURL)
            }
            .help("Download \(connector.name) to install its connector.")
        case .notInstalled:
            Button("Install", action: onInstall)
                .buttonStyle(.borderedProminent)
        case .installing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Installing")
        case .installed:
            Button("Uninstall", role: .destructive, action: onUninstall)
        }
    }
}

private struct ConnectorIcon: View {

    let name: String

    var body: some View {
        Image(name)
            .resizable()
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview(traits: .preview) {
    ConnectorsView()
}
#endif
