import SwiftUI

struct HelpSection: Codable, Identifiable { let id: String, title: String, body: String }
struct OfflineHelpView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ViewState<String> private var query = ""
    @ViewState<[HelpSection]> private var sections = []
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Rill Help").font(.title)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search offline help", text: $query).accessibilityLabel("Search offline help")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(
                        sections.filter {
                            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                                || $0.body.localizedCaseInsensitiveContains(query)
                        }
                    ) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.headline)
                            Text(section.body).textSelection(.enabled).frame(
                                maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(.vertical, 12)
            }
        }.padding(28).frame(width: 850, height: 720)
            .onAppear {
                if let url = Bundle.module.url(forResource: "Help", withExtension: "json"),
                    let data = try? Data(contentsOf: url)
                {
                    sections = (try? JSONDecoder().decode([HelpSection].self, from: data)) ?? []
                }
            }
    }
}
