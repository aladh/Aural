import SwiftUI

struct SettingsView: View {
    @AppStorage(AccentColorOption.storageKey) private var accentColor =
        AccentColorOption.defaultValue

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Accent color") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(accentColor.color)
                            .frame(width: 11, height: 11)
                            .accessibilityHidden(true)

                        Picker("Accent color", selection: $accentColor) {
                            ForEach(AccentColorOption.allCases) { option in
                                Text(option.name)
                                    .tag(option)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityHint("Changes the color used for selections and primary controls")
                    }
                }

                Text("Used for selections, playback controls, and primary actions throughout Aural.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 190)
        .scenePadding()
    }
}
