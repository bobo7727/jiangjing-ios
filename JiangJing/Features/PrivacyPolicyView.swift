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
        let language = Bundle.main.preferredLocalizations.first == "en" ? "en" : "zh"
        guard let value = Bundle.main.object(forInfoDictionaryKey: "JiangJingPrivacyPolicyURL_\(language)") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
