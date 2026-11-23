import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L10n.privacyBody)
                    if let url = publicPolicyURL {
                        Link(L10n.privacyOnline, destination: url)
                    }
                }
                .padding(24)
            }
            .navigationTitle(L10n.privacyTitle)
            .toolbar { Button(L10n.actionClose) { dismiss() } }
        }
    }

    private var publicPolicyURL: URL? {
        // Any Chinese preference (zh-Hans, zh-Hant, zh-HK...) gets the Chinese page; everything else gets English.
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        let language = preferred.hasPrefix("zh") ? "zh" : "en"
        guard let value = Bundle.main.object(forInfoDictionaryKey: "JiangJingPrivacyPolicyURL_\(language)") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
