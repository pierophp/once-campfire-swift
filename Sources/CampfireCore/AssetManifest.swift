import Foundation

/// Build-time asset map. The manifest generator scans `reference/public/assets` and merges the
/// explicit Rust port overrides; the checked-in defaults keep source builds useful without the
/// Rails submodule populated.
public enum AssetManifest {
    public static let stylesheetPath = GeneratedAssetManifest.paths["flash.css"] ?? "/assets/flash-a561c1e5.css"
    public static let assets = GeneratedAssetManifest.paths
}
