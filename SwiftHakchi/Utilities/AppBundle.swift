import Foundation

extension Bundle {
    /// Resource bundle accessor that works inside a .app bundle.
    ///
    /// SPM's auto-generated `Bundle.module` looks at `Bundle.main.bundleURL`
    /// (the .app root), but codesign requires all content inside `Contents/`.
    /// This accessor checks `Bundle.main.resourceURL` (`Contents/Resources/`)
    /// first, then falls back to the SPM-generated `Bundle.module`.
    static let appBundle: Bundle = {
        let bundleName = "SwiftHakchi_SwiftHakchi"

        // .app bundle: Contents/Resources/
        if let resourceURL = Bundle.main.resourceURL {
            let path = resourceURL.appendingPathComponent("\(bundleName).bundle").path
            if let bundle = Bundle(path: path) {
                return bundle
            }
        }

        // Fallback to SPM's auto-generated accessor (works for `swift run`)
        return Bundle.module
    }()
}
