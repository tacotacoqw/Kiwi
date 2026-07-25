import AppKit
import Darwin

if CommandLine.arguments.contains("--import-feishu-secret") {
    do {
        guard let secretPointer = getpass(""),
              !String(cString: secretPointer).isEmpty else {
            throw FeishuCalendarError.invalidConfiguration
        }
        let secret = String(cString: secretPointer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            throw FeishuCalendarError.invalidConfiguration
        }
        let store = FeishuConfigurationStore()
        var configuration = store.load()
        configuration.appSecret = secret
        try store.save(configuration)
        print("Kiwi 飞书密钥已安全导入")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("导入失败：\(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--test-feishu-mobile-notification") {
    let configuration = FeishuConfigurationStore().load()
    guard configuration.hasCredentials,
          !configuration.targetOpenID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
        fputs("Kiwi 飞书配置不完整\n", stderr)
        exit(EXIT_FAILURE)
    }

    let service = FeishuCalendarService()
    Task {
        do {
            try await service.sendCodexCompletionNotification(
                configuration: configuration,
                duration: 6 * 60 + 18
            )
            print("Kiwi 飞书手机测试消息已发送")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("发送失败：\(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
    RunLoop.main.run()
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
