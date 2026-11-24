# StoreKit 本地测试配置

`JiangJing.storekit` 只用于 Xcode 本地测试（Scheme → Run → Options → StoreKit Configuration 选它），
**不在 `JiangJing/` 源码目录里，不会打进 App 包**。商品 ID 必须与 App Store Connect 一致，
`scripts/check-store.py` 会检查它们与代码、`docs/iap-setup.md` 相同。

- `com.jiangjing.magnifier.tip.small` 消耗型 US$0.99（打赏，不解锁任何东西）
- `com.jiangjing.magnifier.pro` 非消耗型 US$2.99（Pro：只解锁带标签副本的导出）

在 Xcode 的 Debug → StoreKit → Manage Transactions 里可以测试：退款、Ask to Buy 待批/批准、失败、离线。
