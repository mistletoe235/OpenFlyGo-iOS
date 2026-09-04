import SwiftUI

struct LanguageSelectionView: View {
    @EnvironmentObject private var settings: AppLanguageSettings
    @Environment(\.dismiss) private var dismiss
    let firstLaunch: Bool

    @State private var pending: AppLanguage

    init(firstLaunch: Bool, initialLanguage: AppLanguage) {
        self.firstLaunch = firstLaunch
        _pending = State(initialValue: initialLanguage)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(firstLaunch ? 0.72 : 0.96).ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.cyan.opacity(0.16)).frame(width: 58, height: 58)
                    Image(systemName: "globe.asia.australia.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(.cyan)
                }

                VStack(spacing: 5) {
                    Text("选择语言").font(.title2.bold())
                    Text("稍后可在设置中随时更改")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    ForEach(AppLanguage.allCases) { language in
                        languageCard(language)
                    }
                }

                Button {
                    settings.select(pending)
                    if !firstLaunch { dismiss() }
                } label: {
                    Text("继续")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(22)
            .frame(width: 430)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.16)))
            .shadow(color: .black.opacity(0.38), radius: 24, y: 10)
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, pending.locale)
    }

    private func languageCard(_ language: AppLanguage) -> some View {
        Button {
            HapticFeedback.selection()
            pending = language
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(language.nativeName).font(.headline)
                    Spacer()
                    Image(systemName: pending == language ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(pending == language ? Color.cyan : Color.secondary)
                }
                Text(language.secondaryName)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background(pending == language ? Color.cyan.opacity(0.12) : Color.white.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(pending == language ? Color.cyan.opacity(0.85) : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
