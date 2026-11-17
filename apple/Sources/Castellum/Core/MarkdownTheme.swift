// Castellum - Markdown compose theme choice (MM-5, task 2695).
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd
//
// The Rust renderer owns the styles (castellum-mail compose_markdown.rs);
// this is only the names the UI offers, matching its `MarkdownTheme::name()`.

import Foundation

enum MarkdownThemeChoice: String, CaseIterable, Identifiable {
    /// Unstyled (the original S46 output).
    case plain
    case clean, serif, compact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: return String(localized: "Plain (no styling)")
        case .clean: return String(localized: "Clean")
        case .serif: return String(localized: "Serif")
        case .compact: return String(localized: "Compact")
        }
    }

    /// Recovers the theme a stored HTML alternative was rendered in, from the
    /// wrapper the core adds (Georgia = serif, 13px = compact, 14px = clean, no
    /// wrapper = plain). Used when a draft is reopened so re-rendering it does
    /// not silently switch it to the Settings default. Tested against the real
    /// renderer for every theme.
    static func infer(fromHtml html: String?) -> MarkdownThemeChoice? {
        guard let html, html.hasPrefix("<div style=\"font-family:") else { return html == nil ? nil : .plain }
        let head = String(html.prefix(220))
        if head.contains("Georgia") { return .serif }
        if head.contains("font-size:13px") { return .compact }
        if head.contains("font-size:14px") { return .clean }
        return .plain
    }

    /// Existing Markdown users keep exactly what they sent before.
    static let defaultChoice: MarkdownThemeChoice = .plain
}
