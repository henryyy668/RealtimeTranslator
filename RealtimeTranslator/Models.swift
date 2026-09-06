import Foundation

/// 会话双方的语言
enum Lang: String {
    case zh
    case en

    /// 语音识别与合成使用的 locale 标识
    var speechLocale: String {
        self == .zh ? "zh-CN" : "en-US"
    }

    var opposite: Lang {
        self == .zh ? .en : .zh
    }
}

/// 一句完整的对话记录:原文 + 译文
struct TranscriptEntry: Identifiable {
    let id = UUID()
    let lang: Lang          // 说话人使用的语言
    let original: String    // 识别出的原文
    let translation: String // 翻译结果
    let date = Date()
}
