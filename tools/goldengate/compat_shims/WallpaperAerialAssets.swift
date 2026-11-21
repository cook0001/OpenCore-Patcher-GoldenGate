import Foundation

public func AerialFallbackAssetURL(_ name: String, withExtension ext: String) -> URL? {
    return Bundle(path: "/System/Library/PrivateFrameworks/WallpaperAerialAssets.framework")?
        .url(forResource: name, withExtension: ext)
}
