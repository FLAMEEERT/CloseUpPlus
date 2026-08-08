import Combine
import CloseUpKit
import SwiftUI

/// General settings: the master enable toggle, launch-at-login, which overlay
/// controls appear, and the in-app language override.
struct GeneralSettingsPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                Toggle(isOn: $appState.isEnabled) {
                    Text(appState.loc("Enable CloseUpPlus"))
                    Text(appState.loc("Show window controls in Mission Control."))
                        .settingsFooter()
                }
                Toggle(appState.loc("Launch at login"), isOn: $appState.launchAtLogin)
                Toggle(appState.loc("Hide Menu Bar Icon"), isOn: $appState.hideMenuBarIcon)
            }

            Section {
                LabeledContent {
                    statusBadge
                } label: {
                    Text(appState.loc("Accessibility"))
                }

                if !appState.accessibilityGranted {
                    Button(appState.loc("Open Accessibility Settings…")) {
                        appState.requestAccessibilityAccess()
                    }
                }

                LabeledContent {
                    screenCaptureStatusBadge
                } label: {
                    Text(appState.loc("Screen Recording"))
                }

                if appState.screenCapturePermissionStatus != .authorized {
                    Button(appState.loc(
                        appState.screenCapturePermissionRequestInFlight
                            ? "Requesting…"
                            : "Set Up Screen Recording…"
                    )) {
                        Task { await appState.requestScreenCaptureAccess() }
                    }
                    .disabled(appState.screenCapturePermissionRequestInFlight)
                }

                screenCapturePermissionMessage
            } header: {
                Text(appState.loc("Permission"))
            } footer: {
                Text(appState.loc("CloseUpPlus uses Accessibility to read Mission Control windows and perform its controls. Screen Recording is separate and used only for Pin: it mirrors only the selected window locally, captures no audio, records or saves no files, uploads no frames, and sends no analytics payload."))
                    .settingsFooter()
            }

            Section {
                Toggle(appState.loc("Close"), isOn: $appState.overlaySettings.showClose)
                Toggle(appState.loc("Minimize"), isOn: $appState.overlaySettings.showMinimize)
                Toggle(appState.loc("Maximize"), isOn: $appState.overlaySettings.showZoom)
            } header: {
                Text(appState.loc("Controls"))
            } footer: {
                Text(appState.loc("Choose which controls appear on each window in Mission Control."))
                    .settingsFooter()
            }

            Section {
                Picker(selection: $appState.languagePreference) {
                    Text(appState.loc("Follow System")).tag(LanguagePreference.system)
                    Divider()
                    ForEach(SupportedLanguage.allCases) { language in
                        Text(language.nativeName).tag(LanguagePreference.specific(language))
                    }
                } label: {
                    Text(appState.loc("Language"))
                }
            } footer: {
                Text(appState.loc("Changes apply immediately."))
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .overlayScrollers()
        .onAppear { appState.refreshPermissionStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshPermissionStatuses()
        }
    }

    private var statusBadge: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: appState.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(appState.accessibilityGranted ? DS.Palette.success : DS.Palette.warning)
            Text(appState.loc(appState.accessibilityGranted ? "Granted" : "Not granted"))
                .foregroundStyle(.secondary)
        }
    }

    private var screenCaptureStatusBadge: some View {
        let granted = appState.screenCapturePermissionStatus == .authorized
        return HStack(spacing: DS.Spacing.xs) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? DS.Palette.success : DS.Palette.warning)
            Text(appState.loc(granted ? "Granted" : "Not granted"))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var screenCapturePermissionMessage: some View {
        switch appState.screenCapturePermissionMessage {
        case .authorized:
            Text(appState.loc("Screen Recording access is available for Pin."))
                .settingsFooter()
        case .setup:
            Text(appState.loc("Screen Recording access is required only for Pin. Set it up before using a selected-window mirror."))
                .settingsFooter()
        case .denied:
            Text(appState.loc("Screen Recording access was denied. Allow it in System Settings to use Pin."))
                .settingsFooter()
        case .needsRetry:
            Text(appState.loc("Screen Recording access was allowed, but CloseUpPlus must be restarted before Pin can use it."))
                .settingsFooter()
        case .revoked:
            Text(appState.loc("Screen Recording access was revoked. Re-enable it to use Pin."))
                .settingsFooter()
        }
    }

}
