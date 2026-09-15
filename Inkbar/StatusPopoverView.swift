import AppKit
import SwiftUI

enum MacGlass {
    static var isLiquid: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }
}

struct StatusPopoverView: View {
    @ObservedObject var overlay: OverlayController
    @ObservedObject private var language = LanguageSettings.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var showSettings = false

    var onAbout: () -> Void
    var onQuit: () -> Void
    var onHideIcon: () -> Void

    private let inset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if showSettings {
                SettingsPaneView(overlay: overlay, onAbout: onAbout, onHideIcon: onHideIcon)
            } else {
                NotchIllustrationView(
                    hideNotch: overlay.isEnabled
                )
                primaryCard
                settingsCard
                footerCard
            }
        }
        .padding(12)
        .frame(width: 332)
        .background(panelBackground)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if showSettings {
                Button {
                    showSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(iconWell)
                }
                .buttonStyle(.plain)
                .help(language.t("back"))

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.t("settings.title"))
                        .font(.headline)
                    Text(language.t("settings.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            } else {
                ZStack {
                    iconWell
                    Image(nsImage: StatusItemController.icon())
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.primary)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Inkbar")
                        .font(.headline)
                    Text(language.t("menu.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(language.t("settings.title"))
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var primaryCard: some View {
        toggleRow(
            title: language.t("hideNotch.title"),
            subtitle: language.t("hideNotch.subtitle"),
            isOn: $overlay.isEnabled,
            prominent: true
        )
        .background(cardBackground)
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            toggleRow(
                title: language.t("dynamic.title"),
                subtitle: language.t("dynamic.subtitle"),
                isOn: $overlay.dynamicWallpapers
            )
            divider
            toggleRow(
                title: language.t("external.title"),
                subtitle: language.t("external.subtitle"),
                isOn: $overlay.coverExternalDisplays
            )
            divider
            toggleRow(
                title: language.t("launch.title"),
                subtitle: language.t("launch.subtitle"),
                isOn: launchBinding
            )
        }
        .background(cardBackground)
    }

    private var footerCard: some View {
        actionRow(language.t("quit"), systemImage: "power", destructive: true) {
            onQuit()
        }
        .background(cardBackground)
    }

    private func toggleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        prominent: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(prominent ? .body.weight(.semibold) : .body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.regular)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, prominent ? 12 : 10)
        .frame(minHeight: prominent ? 58 : 52)
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(destructive ? Color.red.opacity(0.9) : Color.secondary)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.body)
                    .foregroundStyle(destructive ? Color.red.opacity(0.9) : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, inset)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                if LaunchAtLogin.setEnabled(newValue) {
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            }
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, inset)
    }

    private var iconWell: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(MacGlass.isLiquid ? Color.white.opacity(0.10) : Color.primary.opacity(0.06))
    }

    @ViewBuilder
    private var panelBackground: some View {
        if MacGlass.isLiquid {
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(MacGlass.isLiquid ? Color.white.opacity(0.08) : Color.primary.opacity(0.05))
    }
}

struct SettingsPaneView: View {
    @ObservedObject var overlay: OverlayController
    @ObservedObject private var language = LanguageSettings.shared
    var onAbout: () -> Void
    var onQuit: (() -> Void)?
    var onHideIcon: () -> Void

    private let inset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            languageCard

            toggleRow(
                title: language.t("hideIcon.title"),
                subtitle: language.t("hideIcon.subtitle"),
                isOn: hideIconBinding
            )
            .background(cardBackground)

            VStack(spacing: 0) {
                actionRow(language.t("about.title"), systemImage: "info.circle", action: onAbout)
                if let onQuit {
                    divider
                    actionRow(language.t("quit"), systemImage: "power", destructive: true, action: onQuit)
                }
            }
            .background(cardBackground)
        }
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.t("language.title"))
                .font(.body)
                .foregroundStyle(.primary)
            Picker("", selection: $language.language) {
                Text(language.t("language.system")).tag(AppLanguage.system)
                Text(language.t("language.russian")).tag(AppLanguage.russian)
                Text(language.t("language.english")).tag(AppLanguage.english)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var hideIconBinding: Binding<Bool> {
        Binding(
            get: { !overlay.showMenuBarIcon },
            set: { hide in
                if hide {
                    onHideIcon()
                } else {
                    overlay.showMenuBarIcon = true
                }
            }
        )
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.regular)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(destructive ? Color.red.opacity(0.9) : Color.secondary)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.body)
                    .foregroundStyle(destructive ? Color.red.opacity(0.9) : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, inset)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, inset)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(MacGlass.isLiquid ? Color.white.opacity(0.08) : Color.primary.opacity(0.05))
    }
}

struct SettingsWindowView: View {
    @ObservedObject var overlay: OverlayController
    @ObservedObject private var language = LanguageSettings.shared
    var onAbout: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MacGlass.isLiquid ? Color.white.opacity(0.10) : Color.primary.opacity(0.06))
                    Image(nsImage: StatusItemController.icon())
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.primary)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.t("settings.title"))
                        .font(.headline)
                    Text("Inkbar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            SettingsPaneView(overlay: overlay, onAbout: onAbout, onQuit: onQuit, onHideIcon: {
                overlay.showMenuBarIcon = false
            })
        }
        .padding(16)
        .frame(width: 332)
        .background(MacGlass.isLiquid ? Color.clear : Color(nsColor: .windowBackgroundColor))
    }
}
