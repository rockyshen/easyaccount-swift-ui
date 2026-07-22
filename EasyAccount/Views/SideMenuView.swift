import SwiftUI

struct SideMenuView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel

    private let reservedItems: [(icon: String, title: String)] = [
        ("creditcard", "账户管理"),
        ("square.grid.2x2", "分类管理"),
        ("chart.pie", "概览分析"),
        ("clock.arrow.circlepath", "定时任务"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            profileHeader
                .padding(.top, 20)
                .padding(.horizontal, 20)
                .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(reservedItems, id: \.title) { item in
                    menuRow(icon: item.icon, title: item.title) {
                        vm.menuPlaceholderTapped(item.title)
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 16)

            AppearancePicker(mode: appearanceBinding)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            searchBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Button {
                vm.logoutTapped()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                    Text("退出登录")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(EATheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(EATheme.surface.ignoresSafeArea())
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [EATheme.blue, EATheme.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                Text(avatarInitial)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(vm.displayUserName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(EATheme.label)
                    .lineLimit(1)
                Text(vm.connected ? "在线 · 记账助手已连接" : "连接中…")
                    .font(.system(size: 12))
                    .foregroundStyle(EATheme.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(EATheme.tertiary)
            TextField("搜索对话或功能", text: $vm.menuSearch)
                .font(.system(size: 14))
                .foregroundStyle(EATheme.label)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(EATheme.inputFill)
        .clipShape(Capsule())
    }

    private func menuRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(EATheme.label)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(EATheme.label)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EATheme.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var avatarInitial: String {
        let name = vm.displayUserName
        return name.isEmpty ? "账" : String(name.prefix(1))
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { vm.appearanceMode },
            set: { vm.setAppearanceMode($0) }
        )
    }
}
