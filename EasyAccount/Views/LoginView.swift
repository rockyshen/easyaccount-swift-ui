import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel

    var body: some View {
        ZStack {
            EATheme.background.ignoresSafeArea()

            Group {
                switch vm.loginRoute {
                case .landing:
                    landingScreen
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                case .phone:
                    phoneScreen
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                case .phoneCode:
                    phoneCodeScreen
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                case .accountPassword:
                    accountPasswordScreen
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .animation(.easeInOut(duration: 0.28), value: vm.loginRoute)
        }
    }

    // MARK: - Landing

    private var landingScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                AppearancePicker(mode: appearanceBinding, compact: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer(minLength: 24)

            brandHero
                .padding(.bottom, 56)

            VStack(spacing: 14) {
                loginButton(
                    title: "微信登录",
                    icon: "message.fill",
                    foreground: .white,
                    background: EATheme.wechatGreen
                ) {
                    vm.wechatLoginTapped()
                }

                loginButton(
                    title: "手机号登录",
                    icon: "iphone",
                    foreground: EATheme.label,
                    background: EATheme.surfaceElevated
                ) {
                    vm.phoneLoginTapped()
                }

                loginButton(
                    title: "Apple ID 登录",
                    icon: "apple.logo",
                    foreground: EATheme.label,
                    background: EATheme.surfaceElevated
                ) {
                    vm.appleLoginTapped()
                }
            }
            .padding(.horizontal, 28)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    vm.goLoginRoute(.accountPassword)
                }
            } label: {
                Text("使用账号密码登录")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EATheme.secondary)
                    .padding(.top, 18)
            }
            .buttonStyle(.plain)

            if !vm.authError.isEmpty && vm.loginRoute == .landing {
                errorBanner(vm.authError)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
            }

            Spacer()

            agreementRow
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
        }
    }

    private var brandHero: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                EATheme.blue.opacity(0.55),
                                EATheme.cyan.opacity(0.18),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: 120
                        )
                    )
                    .frame(width: 220, height: 220)
                    .blur(radius: 8)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 90 / 255, green: 140 / 255, blue: 255 / 255),
                                Color(red: 40 / 255, green: 70 / 255, blue: 180 / 255)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)
                    .overlay {
                        Text("¥")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: EATheme.blue.opacity(0.45), radius: 24, y: 8)
            }
            .frame(height: 160)

            Text("EasyAccount")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(EATheme.label)
                .tracking(0.5)

            Text("智能记账，开口即记")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(EATheme.secondary)
        }
    }

    // MARK: - Phone

    private var phoneScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            loginNavBar(title: "手机号登录")

            Text("未注册的手机号验证通过后将自动创建账号")
                .font(.system(size: 14))
                .foregroundStyle(EATheme.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            HStack(spacing: 10) {
                Text(vm.countryCode)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(EATheme.label)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(EATheme.inputFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                TextField("请输入手机号", text: $vm.phoneNumber)
                    .keyboardType(.numberPad)
                    .textContentType(.telephoneNumber)
                    .font(.system(size: 17))
                    .foregroundStyle(EATheme.label)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(EATheme.inputFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(vm.loginBusy)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)

            primaryActionButton(
                title: "验证并登录",
                enabled: vm.canContinuePhone
            ) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    vm.continuePhoneLogin()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            if !vm.authError.isEmpty {
                errorBanner(vm.authError)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            }

            Spacer()
        }
    }

    private var phoneCodeScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            loginNavBar(title: "输入验证码")

            Text("验证码已发送至 \(vm.countryCode) \(vm.phoneNumber.filter(\.isNumber))")
                .font(.system(size: 14))
                .foregroundStyle(EATheme.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            Text("开发联调：验证码即账号密码，未注册将自动注册")
                .font(.system(size: 12))
                .foregroundStyle(EATheme.tertiary)
                .padding(.horizontal, 24)
                .padding(.top, 6)

            SecureField("请输入验证码", text: $vm.verifyCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(EATheme.label)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .background(EATheme.inputFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .disabled(vm.loginBusy)

            primaryActionButton(
                title: vm.loginBusy ? "登录中…" : "登录",
                enabled: vm.canSubmitPhoneCode
            ) {
                vm.submitPhoneCodeLogin()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            if !vm.authError.isEmpty {
                errorBanner(vm.authError)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            }

            Spacer()
        }
    }

    // MARK: - Account password (existing backend)

    private var accountPasswordScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                loginNavBar(title: "账号密码登录")

                VStack(alignment: .leading, spacing: 12) {
                    authTabs

                    fieldLabel("用户名")
                    TextField("例如 rocky", text: $vm.loginName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(vm.loginBusy)
                        .foregroundStyle(EATheme.label)
                        .padding(14)
                        .background(EATheme.inputFill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    fieldLabel("密码")
                    HStack(spacing: 8) {
                        Group {
                            if vm.showPassword {
                                TextField("支持英文、数字与符号", text: $vm.loginPassword)
                            } else {
                                SecureField("支持英文、数字与符号", text: $vm.loginPassword)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(vm.loginBusy)
                        .foregroundStyle(EATheme.label)

                        Button(vm.showPassword ? "隐藏" : "显示") {
                            vm.showPassword.toggle()
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(EATheme.blue)
                        .disabled(vm.loginBusy)
                    }
                    .padding(14)
                    .background(EATheme.inputFill)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    primaryActionButton(
                        title: primaryButtonTitle,
                        enabled: vm.canSubmitAuth
                    ) {
                        vm.submitAuth()
                    }
                    .padding(.top, 4)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            vm.showAdvanced.toggle()
                        }
                    } label: {
                        Text(vm.showAdvanced ? "收起连接设置" : "连接设置")
                            .font(.system(size: 14))
                            .foregroundStyle(EATheme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }

                    if vm.showAdvanced {
                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("HTTP Base")
                            TextField("http://118.25.46.207:8088", text: $vm.httpBase)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 14))
                                .foregroundStyle(EATheme.label)
                                .padding(12)
                                .background(EATheme.inputFill)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            fieldLabel("WebSocket")
                            TextField("ws://118.25.46.207:8088", text: $vm.wsUrl)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 14))
                                .foregroundStyle(EATheme.label)
                                .padding(12)
                                .background(EATheme.inputFill)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }

                    if !vm.authError.isEmpty {
                        errorBanner(vm.authError)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Shared pieces

    private var agreementRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.agreedToTerms.toggle()
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: vm.agreedToTerms ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(vm.agreedToTerms ? EATheme.blue : EATheme.tertiary)
                    .padding(.top, 1)

                (
                    Text("我已阅读并同意")
                        .foregroundStyle(EATheme.secondary)
                    + Text("《用户协议》")
                        .foregroundStyle(EATheme.blue)
                    + Text("和")
                        .foregroundStyle(EATheme.secondary)
                    + Text("《隐私政策》")
                        .foregroundStyle(EATheme.blue)
                )
                .font(.system(size: 12))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func loginNavBar(title: String) -> some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    vm.backFromLoginSubpage()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(EATheme.label)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(EATheme.label)

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func loginButton(
        title: String,
        icon: String,
        foreground: Color,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(vm.loginBusy)
    }

    private func primaryActionButton(
        title: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(enabled ? EATheme.blue : EATheme.blueDisabled)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled || vm.loginBusy)
    }

    private var authTabs: some View {
        HStack(spacing: 4) {
            tabButton(title: "登录", mode: .login)
            tabButton(title: "注册", mode: .register)
        }
        .padding(4)
        .background(EATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func tabButton(title: String, mode: AuthMode) -> some View {
        Button {
            vm.switchAuthMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(vm.authMode == mode ? EATheme.label : EATheme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(vm.authMode == mode ? EATheme.surfaceElevated : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .disabled(vm.loginBusy)
        .buttonStyle(.plain)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(EATheme.secondary)
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(EATheme.danger)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EATheme.danger.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var primaryButtonTitle: String {
        if vm.loginBusy {
            return vm.authMode == .register ? "注册中…" : "登录中…"
        }
        return vm.authMode == .register ? "注册并进入" : "登录"
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { vm.appearanceMode },
            set: { vm.setAppearanceMode($0) }
        )
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
