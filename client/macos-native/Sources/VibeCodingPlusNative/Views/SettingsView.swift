import SwiftUI
import EventKit
// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    private var hermesName: String {
        let name = state.config.hermesAssistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Hermes" : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(eyebrow: "CONFIG", title: "设置", subtitle: state.inlineStatus)

            InkPanel(title: "macOS 权限状态", symbol: "checkmark.shield", accent: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 20) {
                        permIndicator("辅助功能", granted: AccessibilitySupport.isTrusted, needed: state.config.sendTarget == .textInjector)
                        permIndicator("麦克风", granted: micPermissionGranted(), needed: state.config.sendTarget != .hermesAgent)
                        permIndicator("提醒事项", granted: reminderPermissionGranted(), needed: state.config.remindersSyncEnabled)
                        Spacer()
                        Button { state.revealAppInFinder() } label: {
                            Label("在 Finder 中显示", systemImage: "folder")
                        }
                        .inkButton()
                        Button { state.openPermissions() } label: {
                            Label("打开权限", systemImage: "lock.open")
                        }
                        .inkButton()
                        Button { Task { await state.refreshEnvironment() } } label: {
                            Label("重新检测", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .inkButton()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前运行的应用")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(InkTheme.ink.opacity(0.5))
                        Text(AccessibilitySupport.runningAppPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(InkTheme.secondaryInk)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }

                    if state.config.sendTarget == .textInjector && !AccessibilitySupport.isTrusted {
                        Text(AccessibilitySupport.reauthorizeHint)
                            .font(.caption)
                            .foregroundStyle(InkTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("注入诊断日志：~/Library/Application Support/vibecoding-plus/inject.log")
                        .font(.caption2)
                        .foregroundStyle(InkTheme.secondaryInk)
                        .textSelection(.enabled)
                }
            }

            InkPanel(title: "运行模式", symbol: "switch.2", accessory: AnyView(sectionHint("语音识别结果如何发送到电脑"))) {
                VStack(spacing: 14) {
                    PickerRow(label: "发送目标", hint: "语音转写后可发到 Hermes、CLI 或当前输入框") {
                        InkSegmentedPicker(
                            selection: Binding(
                                get: { state.config.sendTarget },
                                set: { newValue in
                                    state.config.sendTarget = newValue
                                    state.propagateRuntimeInput()
                                }
                            ),
                            options: SendTarget.allCases,
                            label: { $0.label }
                        )
                    }

                    PickerRow(label: state.config.sendTarget == .hermesAgent ? "发送时机" : "输入时机",
                              hint: state.config.sendTarget == .hermesAgent
                                ? "设备确认=核对转写后发送给 \(hermesName)；立即发送=说完后直接发送"
                                : "设备确认=在墨水屏上点确认才输入；立即输入=说完立刻注入") {
                        InkSegmentedPicker(
                            selection: Binding(
                                get: { state.config.transcriptDeliveryMode },
                                set: { newValue in
                                    state.config.transcriptDeliveryMode = newValue
                                    state.propagateRuntimeInput()
                                }
                            ),
                            options: ["confirm_on_device", "immediate"],
                            label: { $0 == "immediate" ? (state.config.sendTarget == .hermesAgent ? "立即发送" : "立即输入") : "设备确认" }
                        )
                    }

                    if state.config.sendTarget == .textInjector {
                        PickerRow(label: "输入动作", hint: "是否在注入文字后自动按回车") {
                            InkSegmentedPicker(
                                selection: Binding(
                                    get: { state.config.textInjectionMode },
                                    set: { newValue in
                                        state.config.textInjectionMode = newValue
                                        state.propagateRuntimeInput()
                                    }
                                ),
                                options: ["type_and_enter", "type_only"],
                                label: { $0 == "type_only" ? "只输入" : "输入后回车" }
                            )
                        }
                    }

                    PickerRow(label: "语音识别", hint: "选择语音转文字的 provider，下方会显示对应参数") {
                        InkSegmentedPicker(
                            selection: $state.config.sttProvider,
                            options: STTProvider.allCases,
                            label: { $0.label }
                        )
                    }

                    InkFormRow("我的显示名") {
                        TextField("我", text: $state.config.userDisplayName)
                            .textFieldStyle(InkTextFieldStyle())
                    }

                    if state.config.sendTarget == .hermesAgent {
                        PickerRow(label: "语音回复", hint: "\(hermesName) 的文字回复照常显示；开启后也会在 Note 4 播放") {
                            InkSegmentedPicker(
                                selection: $state.config.ttsProvider,
                                options: TTSProvider.allCases,
                                label: { $0.label }
                            )
                        }
                    }

                    InkFormRow("LAN Secret") {
                        SecureField("留空=不鉴权", text: $state.config.lanSharedSecret)
                            .textFieldStyle(InkTextFieldStyle())
                    }
                    InkFormRow("Codex 目录") {
                        PathField(text: $state.config.codexCwd) { state.chooseDirectory(for: .codexExec) }
                    }
                    InkFormRow("Claude 目录") {
                        PathField(text: $state.config.claudeCwd) { state.chooseDirectory(for: .claudeCode) }
                    }
                    if state.config.sendTarget == .hermesAgent {
                        InkFormRow("Hermes 地址") {
                            TextField("http://127.0.0.1:8642", text: $state.config.hermesBaseUrl)
                                .textFieldStyle(InkTextFieldStyle())
                        }
                        InkFormRow("Hermes API Key") {
                            SecureField("必填", text: $state.config.hermesApiKey)
                                .textFieldStyle(InkTextFieldStyle())
                        }
                        InkFormRow("Hermes 会话 ID") {
                            TextField("note4-voice", text: $state.config.hermesSessionId)
                                .textFieldStyle(InkTextFieldStyle())
                        }
                        InkFormRow("Hermes 模型名") {
                            TextField("hermes-agent", text: $state.config.hermesModel)
                                .textFieldStyle(InkTextFieldStyle())
                        }
                        InkFormRow("助手显示名") {
                            TextField("Eira", text: $state.config.hermesAssistantName)
                                .textFieldStyle(InkTextFieldStyle())
                        }
                    }
                }
            }

            usageGuidePanel

            providerSettings

            sharedTTSPanel

            if state.config.ttsProvider == .qwenMlx || SharedTTSManager.installed {
                InkPanel(title: "Qwen 本地语音参数", symbol: "waveform") {
                    VStack(spacing: 12) {
                        InkFormRow("Python 路径") {
                            TextField("", text: $state.config.qwenTTSPython).textFieldStyle(InkTextFieldStyle())
                        }
                        InkFormRow("模型") {
                            TextField("", text: $state.config.qwenTTSModel).textFieldStyle(InkTextFieldStyle())
                        }
                        InkFormRow("参考音频") {
                            TextField("", text: $state.config.qwenTTSReferenceAudio).textFieldStyle(InkTextFieldStyle())
                        }
                        InkFormRow("参考文字") {
                            TextField("", text: $state.config.qwenTTSReferenceText).textFieldStyle(InkTextFieldStyle())
                        }
                        InkFormRow("模型存储目录") {
                            TextField("", text: $state.config.qwenTTSCacheDirectory).textFieldStyle(InkTextFieldStyle())
                        }
                        sectionHint("这里统一设置共享语音服务的模型与音色，保存后 Hermes 和 Note 4 都使用同一份配置。")
                    }
                }
            }

            InkPanel(title: "应用行为", symbol: "gearshape") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("开机启动", isOn: $state.desktopSettings.autoLaunch)
                    Toggle("隐藏启动", isOn: $state.desktopSettings.launchToTray)
                    Toggle("关闭时保留菜单栏运行", isOn: $state.desktopSettings.closeToTray)
                    Toggle("Codex 跳过 Git 仓库检查", isOn: $state.config.codexSkipGitRepoCheck)
                    Toggle("Claude 跳过权限确认", isOn: $state.config.claudeDangerouslySkipPermissions)
                }
                .toggleStyle(InkCheckboxToggleStyle())
            }

        }
        .onAppear {
            Task { await state.refreshEnvironment() }
        }
        .task {
            while !Task.isCancelled {
                await state.refreshTTSStatus()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    private var sharedTTSPanel: some View {
        InkPanel(title: "共享语音服务", symbol: "speaker.wave.2") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(state.ttsStatus?.label ?? "服务未运行",
                          systemImage: state.ttsStatus == nil ? "circle" : "checkmark.circle.fill")
                    Spacer()
                    Text("Eira · Hermes 与 Note 4 共用")
                        .font(.caption).foregroundStyle(InkTheme.secondaryInk)
                }
                Toggle("保持模型加载", isOn: $state.config.qwenTTSKeepWarm)
                    .toggleStyle(InkCheckboxToggleStyle())
                if !state.config.qwenTTSKeepWarm {
                    InkFormRow("空闲后释放") {
                        Picker("空闲后释放", selection: $state.config.qwenTTSIdleSeconds) {
                            Text("1 分钟").tag(60)
                            Text("5 分钟").tag(300)
                            Text("10 分钟").tag(600)
                            Text("15 分钟").tag(900)
                        }.labelsHidden()
                    }
                }
                HStack(spacing: 10) {
                    Button("启动") { Task { await state.manageTTS("start") } }.inkButton()
                    Button("停止") { Task { await state.manageTTS("stop") } }.inkButton()
                    Button("重启") { Task { await state.manageTTS("restart") } }.inkButton()
                    Button("释放模型") { Task { await state.manageTTS("release") } }.inkButton()
                    Button("试音") { Task { await state.manageTTS("test") } }.inkButton()
                    Button("查看日志") { state.openTTSLog() }.inkButton()
                    if state.ttsServiceBusy { ProgressView().controlSize(.small) }
                }.disabled(state.ttsServiceBusy)
                if !state.ttsServiceMessage.isEmpty {
                    Text(state.ttsServiceMessage).font(.caption).textSelection(.enabled)
                }
                if let error = state.ttsStatus?.last_error, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(InkTheme.warning).textSelection(.enabled)
                }
                sectionHint("服务随登录启动，退出本应用后 Hermes 仍可使用。空闲释放保留服务入口，下次说话自动加载模型。更改选项后点“保存并应用”。")
            }
        }
    }

    private func permIndicator(_ name: String, granted: Bool, needed: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: granted ? "checkmark.circle.fill" : (needed ? "exclamationmark.triangle.fill" : "circle"))
                .foregroundStyle(granted ? InkTheme.ink : (needed ? InkTheme.warning : .secondary))
            Text(name)
                .font(.callout.weight(.medium))
            if !granted && needed {
                Text("未授权")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(InkTheme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(InkTheme.warning.opacity(0.15), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var providerSettings: some View {
        InkPanel(title: "\(state.config.sttProvider.label) 参数", symbol: "waveform.path.ecg") {
            VStack(spacing: 12) {
                switch state.config.sttProvider {
                case .volcengine:
                    InkFormRow("App Key") { TextField("", text: $state.config.volcengineAppKey).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("Access Key") { SecureField("", text: $state.config.volcengineAccessKey).textFieldStyle(InkTextFieldStyle()) }
                case .openai:
                    InkFormRow("API Key") { SecureField("", text: $state.config.openaiApiKey).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("模型") { TextField("", text: $state.config.openaiModel).textFieldStyle(InkTextFieldStyle()) }
                    VStack(alignment: .leading, spacing: 6) {
                        InkFormRow("API 地址") {
                            TextField("https://api.openai.com/v1", text: $state.config.openaiBaseUrl)
                                .textFieldStyle(InkTextFieldStyle())
                        }
                        sectionHint("兼容 OpenAI 的第三方接口地址，留空则使用官方 https://api.openai.com/v1")
                            .padding(.leading, 146)
                    }
                case .whisperCpp:
                    InkFormRow("模型路径") { TextField("", text: $state.config.whisperCppModelPath).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("命令") { TextField("", text: $state.config.whisperCppCommand).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("语言") { TextField("", text: $state.config.whisperCppLanguage).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("线程") { TextField("", text: $state.config.whisperCppThreads).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("额外参数") { TextField("", text: $state.config.whisperCppExtraArgs).textFieldStyle(InkTextFieldStyle()) }
                case .qwenAsr:
                    InkFormRow("API Key") { SecureField("", text: $state.config.qwenAsrApiKey).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("模型") { TextField("", text: $state.config.qwenAsrModel).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("语言") { TextField("", text: $state.config.qwenAsrLanguage).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("采样率") { TextField("", text: $state.config.qwenAsrSampleRate).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("Realtime URL") { TextField("", text: $state.config.qwenAsrRealtimeBaseUrl).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("提示词") { TextField("", text: $state.config.qwenAsrPrompt).textFieldStyle(InkTextFieldStyle()) }
                case .qwenMlx:
                    InkFormRow("Python 路径") { TextField("", text: $state.config.qwenMlxPython).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("模型") {
                        Picker("模型", selection: $state.config.qwenMlxModel) {
                            Text("0.6B · 速度优先").tag("Qwen/Qwen3-ASR-0.6B")
                            Text("1.7B · 准确率优先").tag("Qwen/Qwen3-ASR-1.7B")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    InkFormRow("语言") { TextField("", text: $state.config.qwenMlxLanguage).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("术语提示") { TextField("", text: $state.config.qwenMlxContext).textFieldStyle(InkTextFieldStyle()) }
                    InkFormRow("模型存储目录") { TextField("", text: $state.config.qwenMlxCacheDirectory).textFieldStyle(InkTextFieldStyle()) }
                    sectionHint("术语提示帮助识别专有名词，不会清除语气词。")
                    sectionHint("在 Mac 上运行；切换模型后保存并应用。首次使用新模型时需要加载或下载。")
                }
            }
        }
    }

    @ViewBuilder
    private var usageGuidePanel: some View {
        InkPanel(title: "使用说明", symbol: "book.pages",
                 accessory: AnyView(sectionHint(state.config.sendTarget == .hermesAgent ? "Hermes 语音模式" : "文本输入模式按键说明"))) {
            VStack(alignment: .leading, spacing: 10) {
                if state.config.sendTarget == .hermesAgent {
                    UsageKeyRow(symbol: "rectangle.roundedtop.fill", action: "长按 BOOT",
                                detail: "录音；松开后在 Mac 上识别，并在设备上显示文字")
                    if state.config.transcriptDeliveryMode == "confirm_on_device" {
                        UsageKeyRow(symbol: "arrow.up", action: "上键",
                                    detail: "确认并发送识别文字给 \(hermesName)")
                        UsageKeyRow(symbol: "arrow.down", action: "下键",
                                    detail: "撤销待发送的文字")
                    } else {
                        UsageKeyRow(symbol: "paperplane", action: "松开 BOOT 后",
                                    detail: "识别文字自动发送给 \(hermesName)")
                    }
                    UsageKeyRow(symbol: "text.bubble", action: "等待回复",
                                detail: "\(hermesName) 的文字回答会显示在设备上")
                } else {
                    UsageKeyRow(symbol: "rectangle.roundedtop.fill", action: "长按 BOOT",
                                detail: "开始录音，松开后自动识别并输入到光标处")
                    UsageKeyRow(symbol: "arrow.forward.square", action: "继续长按 BOOT",
                                detail: "在已输入内容后追加新识别的文字")
                    UsageKeyRow(symbol: "corner.downleft", action: "短按 BOOT",
                                detail: "发送回车（提交当前输入框）")
                    UsageKeyRow(symbol: "xmark.square", action: "连按两次 BOOT",
                                detail: "清空输入框中已输入的内容")
                    UsageKeyRow(symbol: "arrow.up.arrow.down", action: "上 / 下 键",
                                detail: "翻页 / 切换模式（不参与发送）")
                }
            }
        }
    }
}

/// 固定在设置页下沿，使长表单中的任意位置都能保存。
struct SettingsActionBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PageActionBar {
            Button { Task { await state.saveSettings() } } label: {
                Label("保存并应用", systemImage: "checkmark.circle.fill")
            }
            .inkProminentButton()
            .keyboardShortcut("s", modifiers: .command)
            Button { state.openConfigFolder() } label: {
                Label("打开配置目录", systemImage: "folder")
            }
            .inkButton()
            Spacer()
            Text(SettingsStore().configURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(InkTheme.secondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct UsageKeyRow: View {
    let symbol: String
    let action: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(InkTheme.accent)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(action)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(InkTheme.secondaryInk)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
