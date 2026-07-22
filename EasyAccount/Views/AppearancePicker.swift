import SwiftUI

struct AppearancePicker: View {
    @Binding var mode: AppearanceMode
    var compact: Bool = false

    var body: some View {
        if compact {
            Menu {
                ForEach(AppearanceMode.allCases) { item in
                    Button {
                        mode = item
                    } label: {
                        HStack {
                            Text(item.title)
                            if mode == item {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(EATheme.label)
                    .frame(width: 36, height: 36)
                    .background(EATheme.surfaceElevated)
                    .clipShape(Circle())
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("外观")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(EATheme.secondary)
                    .padding(.horizontal, 4)

                Picker("外观", selection: $mode) {
                    ForEach(AppearanceMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var iconName: String {
        switch mode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}
