import SwiftUI
import ImageIO
import RillCore

struct ResponseBodyPreview: View {
    let exchange: Exchange
    let pretty: Bool
    let fontSize: Double
    @ViewState<CGImage?> private var image: CGImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ResponseInspection.kind(exchange).rawValue).font(.caption).foregroundStyle(.secondary)
                if exchange.bodyWasTruncated == true { Text("Retained snapshot: \(exchange.body.count) of \(exchange.originalBodyBytes ?? exchange.body.count) bytes").font(.caption).foregroundStyle(.orange) }
            }.padding(.horizontal, 20)
            if exchange.bodyWasTruncated == true && exchange.body.isEmpty {
                ContentUnavailableView("Body not retained", systemImage: "archivebox", description: Text("Snapshot bodies are omitted by default. Metadata and checks remain available."))
            } else if ResponseInspection.kind(exchange) == .image {
                if let image { ScrollView { Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxWidth: 1024).padding(20) } }
                else { ContentUnavailableView("Image preview unavailable", systemImage: "photo", description: Text("Only complete PNG/JPEG/GIF payloads within preview and pixel limits are decoded. Export retained bytes to inspect.")) }
            } else {
                if ResponseInspection.kind(exchange) == .html { Text("HTML is shown as source. Scripts and remote resources are never loaded.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20) }
                ScrollView([.vertical, .horizontal]) {
                    Text(ResponseInspection.kind(exchange) == .binary ? ResponseInspection.hex(exchange.body) : exchange.previewText(pretty: pretty))
                        .font(.system(size: fontSize, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
                }
                if ResponseInspection.kind(exchange) == .binary { Text("Hex preview: first 4 KiB. Export preserves retained bytes.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: exchange.id) {
            image = nil
            guard ResponseInspection.kind(exchange) == .image, !exchange.previewIsTruncated, exchange.bodyWasTruncated != true else { return }
            let data = exchange.body
            let decode = Task.detached(priority: .userInitiated) { Self.decodeImage(data) }
            let decoded = await withTaskCancellationHandler { await decode.value } onCancel: { decode.cancel() }
            if !Task.isCancelled { image = decoded }
        }
    }
    nonisolated private static func decodeImage(_ data: Data) -> CGImage? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg", "com.compuserve.gif"].contains(type),
              CGImageSourceGetCount(source) <= 1000,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 16_000_000 else { return nil }
        guard !Task.isCancelled else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
