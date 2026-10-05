import Foundation

/// Build-time asset map. The manifest generator scans `reference/public/assets` and merges the
/// explicit Rust port overrides; the checked-in defaults keep source builds useful without the
/// Rails submodule populated.
public enum AssetManifest {
    public static let stylesheetPath = GeneratedAssetManifest.paths.keys.filter { $0.hasSuffix(".css") }.sorted().first.flatMap { GeneratedAssetManifest.paths[$0] } ?? "/assets/flash-a561c1e5.css"
    static let stylesheetTags = GeneratedAssetManifest.stylesheetTags
    static let importmapTags = GeneratedAssetManifest.importmapTags
    public static let assets = GeneratedAssetManifest.paths
}
