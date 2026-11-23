import Foundation

/// App Store Connect product identifiers. They must match `StoreKitConfig/JiangJing.storekit`
/// and the products created in App Store Connect (checked by `scripts/check-store.py`).
enum StoreCatalog {
    /// Consumable. A voluntary tip: it never unlocks anything.
    static let tipSmallID = "com.jiangjing.magnifier.tip.small"
    /// Non-consumable. Unlocks only the new label-stamp export.
    static let proID = "com.jiangjing.magnifier.pro"

    static let tipIDs: Set<String> = [tipSmallID]
    static let allIDs: Set<String> = tipIDs.union([proID])
}
