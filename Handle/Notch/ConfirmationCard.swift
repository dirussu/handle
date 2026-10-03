import AppKit
import SwiftUI
import MarkdownUI

struct ConfirmationCard: View {
    let request: ConfirmationRequest

    var body: some View {
        VStack(alignment: .leading, spacing: HandleSpacing.m) {
            HStack(spacing: HandleSpacing.s) {
                if request.isDestructive {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
                Text(request.title)
                    .font(.handleSection)
                    .foregroundStyle(.primary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: HandleSpacing.s) {
                ForEach(Array(request.detailRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: HandleSpacing.m) {
                        Text(row.label)
                            .font(.handleCaption)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(row.value)
                            .font(.handleBody)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(HandleSpacing.m)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }

            HStack(spacing: 10) {
                Button(request.cancelLabel) {
                    request.onDecision(false)
                }
                .buttonStyle(.handleSolid)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(request.confirmLabel) {
                    request.onDecision(true)
                }
                .buttonStyle(request.isDestructive ? .handleSolidDestructive : .handleSolidProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(HandleSpacing.l)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.10))
        }
    }
}

// MARK: - Markdown theme tuned for Handle's compact glass panel

extension Theme {
    /// Markdown theme aligned with Handle's type ramp:
    /// - body: 13pt regular (handleBody)
    /// - h1:   17pt semibold
    /// - h2:   15pt semibold
    /// - h3:   14pt semibold (handleSection)
    /// - code: 12pt monospaced
    static let handleCompact: Theme = Theme()
        .text {
            FontSize(13)
            ForegroundColor(.primary)
        }
        .strong {
            FontWeight(.semibold)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(12)
            BackgroundColor(.primary.opacity(0.08))
        }
        .link {
            ForegroundColor(.white)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.30))
                .markdownMargin(top: .em(0), bottom: .em(0.6))
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.20), bottom: .em(0))
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.6), bottom: .em(0.4))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.5), bottom: .em(0.35))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(15)
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.3))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14)
                }
        }
        .codeBlock { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.25))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(12)
                }
                .padding(12)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .foregroundStyle(.secondary)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 2)
                }
        }
        .table { configuration in
            configuration.label
                .markdownTableBorderStyle(.init(.allBorders, color: .primary.opacity(0.18)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(.clear, Color.white.opacity(0.04))
                )
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle { FontSize(12) }
                .padding(.horizontal, HandleSpacing.s)
                .padding(.vertical, HandleSpacing.xs)
        }
}
