import SwiftUI

/// ⌘, — the AI provider key and translation switch.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var status: Status?
    @State private var testing = false

    private enum Status {
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("服务商", selection: providerID) {
                    ForEach(LLMProvider.all, id: \.id) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                .pickerStyle(.segmented)
                SecureField("API key", text: $key, prompt: Text(model.hasAPIKey ? "已保存（输入新 key 可替换）" : model.provider.keyPlaceholder))
                HStack {
                    Button("保存") { save() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("测试翻译") { test() }
                        .disabled(!model.hasAPIKey || testing)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    if model.hasAPIKey {
                        Button("删除 key", role: .destructive) { delete() }
                    }
                }
                if let status {
                    switch status {
                    case .success(let text): Label(text, systemImage: "checkmark.circle").foregroundStyle(.green)
                    case .failure(let text): Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("AI 服务：\(model.provider.name)")
            } footer: {
                Text("每家服务商的 key 分开保存在本机钥匙串里。翻译用 \(model.provider.fastModel)（\(model.provider.fastModelNote)），费用记在你自己的 \(model.provider.name) 账户上。切换后对下一次录音生效，正在录的这节课不变。")
                    .foregroundStyle(.secondary)
            }
            Section("翻译") {
                Toggle("把正式字幕实时翻译成中文", isOn: $model.translationEnabled)
            }
            Section {
                Toggle("用 AI 判断老师讲到了哪一页", isOn: $model.slideLocatorEnabled)
            } header: {
                Text("课件跟随")
            } footer: {
                Text("每 30 秒让 \(model.provider.fastModel) 根据最近的转录判断当前页，比只比对文字准得多，一节两小时的课约 0.03 美元。关闭后只用本机的文字比对。对下次打开的课件生效。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("识别老师向全班的提问，并自动生成参考答案", isOn: $model.questionsEnabled)
            } header: {
                Text("提问")
            } footer: {
                Text("先用 \(model.provider.fastModel) 判断是不是真提问（排除自问自答和“right?”这类口头禅），再用 \(model.provider.strongModel) 生成答案。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The picker works on provider ids; switching clears the key field and the last test result,
    /// which belonged to the other provider.
    private var providerID: Binding<String> {
        Binding(
            get: { model.provider.id },
            set: { id in
                guard let provider = LLMProvider.named(id), provider.id != model.provider.id else { return }
                model.provider = provider
                key = ""
                status = nil
            }
        )
    }

    private func save() {
        do {
            try model.saveAPIKey(key)
            key = ""
            status = .success("已保存")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func delete() {
        do {
            try model.deleteAPIKey()
            status = nil
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func test() {
        testing = true
        Task {
            switch await model.testTranslation() {
            case .success(let text): status = .success(text)
            case .failure(let error): status = .failure(error.localizedDescription)
            }
            testing = false
        }
    }
}
