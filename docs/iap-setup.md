# 内购设置（打赏 + Pro）

方案：`.agents/work/tip-pro/PLAN.md`（本地过程文件，不入库）。老板 2026-11-23 批准：标签水印作为 Pro；打赏 US$0.99 消耗型；Pro US$2.99 非消耗型。

| 项 | 类型 | Product ID（创建后不可改、不可重建） | 参考名称 | 美区价格 | Family Sharing |
| --- | --- | --- | --- | --- | --- |
| 打赏 | Consumable | `com.jiangjing.magnifier.tip.small` | Tip - Small | US$0.99 | 不适用 |
| Pro | Non-Consumable | `com.jiangjing.magnifier.pro` | Magnifier Pro | US$2.99 | **关闭**（开启后不能再关闭） |

## 本地化（ASC 的 App Store Localization 需要三套；展示名 ≤30 字符，描述 ≤45 字符）

| 商品 | 语言 | 展示名 | 描述 |
| --- | --- | --- | --- |
| tip.small | English (U.S.) | Tip the Developer | A thank-you. Unlocks nothing. |
| tip.small | Chinese (Simplified) | 打赏开发者 | 表示感谢，不解锁任何功能。 |
| tip.small | Chinese (Traditional) | 打賞開發者 | 表達感謝，不會解鎖任何功能。 |
| pro | English (U.S.) | Magnifier Pro | Add your name or a client label to photos. |
| pro | Chinese (Simplified) | 匠镜 Pro | 给照片加上你的名字或客户名。一次购买。 |
| pro | Chinese (Traditional) | 匠鏡 Pro | 為照片加上你的名字或客戶名稱。一次購買。 |

## 老板在 App Store Connect 要做的事

1. 开发者后台 → Identifiers → `com.jiangjing.magnifier`：确认 **In-App Purchase** 能力已开（通常默认开）。
2. ASC → Business（协议、税务和银行业务）：**Paid Apps Agreement 为 Active**，银行和税表已填。
3. 申请 **Apple 小企业计划**（仅 Account Holder）：https://developer.apple.com/app-store/small-business-program/
4. ASC → 我的 App → 匠镜 → Monetization → In-App Purchases → “+”：
   Consumable，Reference Name `Tip - Small`，Product ID `com.jiangjing.magnifier.tip.small`，价格选美区 US$0.99，
   Availability 同 App，按上表加三种语言，Review Information 上传支持页截图，Review Notes 写：
   `Voluntary tip. Unlocks no feature. The app is fully usable without any purchase.`；保存后状态应为 Ready to Submit。
5. 新建 App 版本；打开该商品点 **Add for Review**，核对提交草稿里**同时有商品和 App 版本**再提交（首个某类型内购必须随新版本提交）。
6. Users and Access → Sandbox → Test Accounts 建沙盒测试账号；真机 Settings → Developer → Sandbox Apple Account 登录。
7. App Privacy 复核仍答“不收集数据”（购买由 Apple 处理，应用不记录购买信息，无服务端校验）；公开的隐私政策网页按 `docs/privacy/*.html` 同步。
8. Pro 商品（非消耗型）在 Pro 功能批准上线时再建：步骤同第 4–5 步，Review Notes 写明
   `Pro only unlocks the new photo label feature; every existing feature is free; Restore Purchases is on the paywall and Support page.`

本地测试配置：`StoreKitConfig/JiangJing.storekit`（见同目录 README）。
