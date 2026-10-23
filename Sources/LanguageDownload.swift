import SwiftUI
import Translation

/// Hosting a `translationTask` is the supported way to make macOS show its language-download sheet.
struct LanguageDownloadView: View {
    let source: Locale.Language
    let target: Locale.Language
    let onDone: () -> Void

    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Preparing translation languages…")
        }
        .padding(32)
        .onAppear { configuration = .init(source: source, target: target) }
        .translationTask(configuration) { session in
            try? await session.prepareTranslation()
            onDone()
        }
    }
}
