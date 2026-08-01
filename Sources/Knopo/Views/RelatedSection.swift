import SwiftUI
import KnopoCore

/// Meaning-based neighbors for a page, backed entirely by Apple's on-device
/// contextual embedding model and the rebuildable cache index.
struct RelatedSection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let pageName: String
    var blockID: UUID? = nil

    @State private var hits: [SemanticHit] = []
    @State private var loading = true

    var body: some View {
        let refreshID = "\(PageName.key(pageName))#\(blockID?.uuidString ?? "page")#\(app.dataVersion)#\(app.semanticDataVersion)"
        let status = app.embeddingIndexStatus
        let unavailable = app.semanticUnavailableReason

        Group {
            if unavailable != nil || loading || !hits.isEmpty || status?.isComplete == false {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Related").font(.headline)
                        if !hits.isEmpty {
                            Text("\(hits.count)")
                                .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }

                    if let unavailable {
                        Text(unavailable)
                            .font(.caption).foregroundStyle(.secondary)
                    } else if hits.isEmpty, loading {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Finding related notes…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if !hits.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(hits, id: \.hit.blockID) { semantic in
                                relatedRow(semantic.hit)
                            }
                        }
                    }

                    if let status, !status.isComplete, status.total > 0 {
                        HStack(spacing: 8) {
                            ProgressView(value: Double(status.completed), total: Double(status.total))
                                .frame(width: 90)
                            Text("Preparing semantic index \(status.completed) of \(status.total)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .task(id: refreshID) {
            loading = true
            hits = await app.related(toPageNamed: pageName, blockID: blockID)
            loading = false
        }
    }

    private func relatedRow(_ hit: SearchHit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(Color.secondary.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(pageDisplayTitle(hit.pageDisplayName))
                    .font(.caption).foregroundStyle(.secondary)
                Text(AttributedString(BlockRenderer.render(
                    content: hit.content,
                    context: BlockRenderer.Context(
                        resolveBlockRef: { [weak app] id in
                            app?.store.resolveBlock(id)?.block.content
                        },
                        assetsDir: app.store.assetsDir,
                        tables: false))))
                .lineLimit(3)
                .environment(\.openURL, OpenURLAction { url in
                    nav.openURL(url, inSidebar: wantsSidebarClick())
                    return .handled
                })
            }
            Spacer(minLength: 0)
            Button {
                nav.navigateToBlock(
                    pageName: hit.pageDisplayName, blockID: hit.blockID,
                    content: hit.content, inSidebar: wantsSidebarClick())
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Go to related block")
        }
        .padding(.vertical, 2)
    }
}
