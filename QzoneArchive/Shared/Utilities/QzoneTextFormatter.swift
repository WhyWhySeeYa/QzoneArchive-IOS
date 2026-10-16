//
//  QzoneTextFormatter.swift
//  QzoneArchive
//
//  空间正文渲染: 提及语法, 表情, 换行
//

import Foundation
import SwiftUI

/// 把 QQ 空间的原始正文转成可显示的富文本
enum QzoneTextFormatter {
    /// 提及语法: @{uin:xxx,nick:yyy}
    private static let mentionPattern = #"@\{uin:([^,}]+),nick:([^}]+)\}"#

    /// 渲染正文, 返回带高亮的文本
    static func render(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        // 去掉正文开头的冒号与前导空白
        var working = text
        while working.hasPrefix("：") || working.hasPrefix(":") { working.removeFirst() }
        working = working.trimmingCharacters(in: .whitespacesAndNewlines)
        if working.isEmpty { return AttributedString("该动态没有文字内容") }
        result = AttributedString(working)

        // 替换提及语法
        if let regex = try? NSRegularExpression(pattern: mentionPattern) {
            let nsString = working as NSString
            let matches = regex.matches(
                in: working,
                range: NSRange(location: 0, length: nsString.length)
            )
            for match in matches.reversed() {
                guard let range = Range(match.range, in: working) else { continue }
                let uin = nsString.substring(with: match.range(at: 1))
                let nick = nsString.substring(with: match.range(at: 2))
                let display = AttributedString("@\(nick)")
                var attributed = display
                attributed.foregroundColor = .accentColor
                attributed.link = URL(string: "qzonearchive://user/\(uin)")
                if let attributedRange = result.range(of: display) {
                    result.replaceSubrange(attributedRange, with: attributed)
                }
            }
        }
        return result
    }

    /// 纯文本形态, 用于导出与搜索
    static func plain(_ text: String) -> String {
        var working = text
        while working.hasPrefix("：") || working.hasPrefix(":") { working.removeFirst() }
        if let regex = try? NSRegularExpression(pattern: mentionPattern) {
            let nsString = working as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: working, range: NSRange(location: 0, length: nsString.length)) {
                result += nsString.substring(with: NSRange(location: last, length: match.range.location - last))
                result += "@" + nsString.substring(with: match.range(at: 2))
                last = match.range.location + match.range.length
            }
            result += nsString.substring(from: last)
            working = result
        }
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
