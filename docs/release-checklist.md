# 匠镜发布前检查清单

适用于匠镜的 TestFlight 内部测试及后续 App Store 送审。本文记录仓库依据和待执行检查，所有发布复选框默认未勾选，不表示发布条件已经满足。每次发布请记录负责人、提交号、版本/构建号、验收设备和结果。操作说明见 [Codemagic → TestFlight](codemagic.md)，商店字段见 [商店文案](store-copy.md)。

## 一、共同前置检查

### 项目身份与版本

仓库依据：[工程描述](../project.yml)、[Info.plist](../JiangJing/Info.plist)。应用使用 SwiftUI，面向 iPhone、iOS 16+，固定竖屏；Bundle ID 为 `com.jiangjing.magnifier`，当前营销版本为 `1.0.0`，仓库默认构建号为 `1`。

- [ ] 核对本次提交、应用名称、Bundle ID、目标平台及最低系统版本，确认 ASC（App Store Connect）应用记录属于正确团队。
- [ ] 营销版本使用 `MARKETING_VERSION`，对应 `CFBundleShortVersionString`；首版保持 `1.0.0`，后续按实际发布版本递增，并与 ASC 版本记录一致。
- [ ] 发布构建号使用 Codemagic 提供的正整数 `PROJECT_BUILD_NUMBER`，工作流通过 `agvtool` 写入 `CURRENT_PROJECT_VERSION` / `CFBundleVersion`。上传前与 ASC 历史记录核对，确保递增且未使用；重新上传新包应使用新构建号，不能只依赖仓库默认值或假定 CI 编号永不重置。

### 隐私政策网址：TestFlight 前置条件

当前源文件中两个政策网址为空；[中文页面](privacy/zh.html)和[英文页面](privacy/en.html)是待发布材料，仓库有 HTML 不等于已有公开网址。发布责任人须先核实主体、联系方式、更新日期与实际数据处理行为，再另行发布真实页面。

| Codemagic 变量组 `jiangjing_release` | 发布构建的 Info.plist 键 | 应用内用途 |
| --- | --- | --- |
| `PRIVACY_POLICY_URL_ZH` | `JiangJingPrivacyPolicyURL_zh` | 简体中文政策网页链接 |
| `PRIVACY_POLICY_URL_EN` | `JiangJingPrivacyPolicyURL_en` | 英文政策网页链接 |

- [ ] 两个网址均为真实、无需登录即可公开访问的 HTTPS 页面，语言、应用标识、政策内容正确，不使用示例地址。
- [ ] 变量组、发布包中的对应键、ASC 对应语言的 Privacy Policy URL 三处一致；安装后用中英文分别打开验证。
- [ ] 应用内政策正文与网页一致，既可阅读内置正文，也可打开公开 HTTPS 政策链接。实现依据为 [PrivacyPolicyView](../JiangJing/Features/PrivacyPolicyView.swift)及[中英文资源](../JiangJing/Resources)。
- [ ] 理解 [check-release-policy.py](../scripts/check-release-policy.py) 的边界：它在签名前读取上述变量，检查 HTTPS 响应及页面标识，再写入本次构建的 plist；它不能认证政策完整性、主体真实性或申报正确性。本清单核对阶段不运行这个会写入 plist 的脚本。

### App Privacy 营养标签

仓库依据：[隐私清单](../JiangJing/PrivacyInfo.xcprivacy)声明不追踪、无收集数据类型；当前实现没有账户、广告、分析 SDK 或向开发者上传媒体的功能。照片、视频及保存状态先保留在应用私有目录，相册仅添加，分享由用户主动打开系统面板。**“不收集数据”是待发布责任人确认的建议答案，不是已完成的 ASC 申报。**

- [ ] 按 Apple 的“收集”定义核查全部数据流：将数据传出设备，并允许开发者或第三方合作方在完成实时请求所需时间之外访问。只在设备上处理的数据不属于此定义的收集。[Apple 隐私填报说明](https://developer.apple.com/app-store/app-privacy-details/)
- [ ] 核实私有媒体保留、相册写入、系统相册/iCloud 同步以及用户主动分享的边界。不能把系统或用户所选服务的行为直接当作应用向开发者上传，也不能据此免查开发者实际接收的数据。
- [ ] 单独确认开发者是否通过 Apple 服务、ASC/Organizer 诊断报告或其他服务实际获取、保留及使用崩溃、诊断或其他数据。Apple 自身收集与开发者通过 Apple 服务收集应区分；不能仅因查看工具就自动判断必须申报 Crash Data，也不能直接忽略实际收集。[Apple 对框架和服务的说明](https://developer.apple.com/app-store/app-privacy-details/)
- [ ] 根据核实结果在 ASC 完成 App Privacy；如存在收集，逐项确认数据类型、用途、是否关联身份及是否用于追踪。复核政策、构建内容与标签一致；隐私清单不能替代 ASC 问卷。

### 权限说明与触发时机

以下原样引用当前 [Info.plist](../JiangJing/Info.plist)、[中文权限文案](../JiangJing/Resources/zh-Hans.lproj/InfoPlist.strings)及[英文权限文案](../JiangJing/Resources/en.lproj/InfoPlist.strings)。

| 权限键 | 简体中文 | English | 触发时机 |
| --- | --- | --- | --- |
| `NSCameraUsageDescription` | 需要使用相机，把屏幕当成放大镜，看清细小零件，并拍下照片和视频。 | The camera is used as a magnifier so you can see fine detail and capture photos and video. | 首次点击“允许使用相机”后请求相机授权 |
| `NSMicrophoneUsageDescription` | 打开录像声音时，需要使用麦克风收录环境声。 | The microphone is used only when you turn on sound for a video recording. | 用户开启录像声音时请求；默认关闭 |
| `NSPhotoLibraryAddUsageDescription` | 需要把放大后的照片和视频保存到相册，方便发给客户或朋友。 | Photos and videos of the magnified view are saved to your library so you can send them to customers or friends. | 首次保存采集内容到相册时请求；首次授权延后至前台 |

- [ ] 在中英文真机上核对弹窗实际文本、触发时机和拒绝后的提示/设置入口。
- [ ] 确认相册仍使用 [PhotoLibrarySaver](../JiangJing/Media/PhotoLibrarySaver.swift) 的 `.addOnly`，无需读取整个相册；保存被拒绝后仍能保留本机文件并主动分享/重试。
- [ ] 核对录音关闭后新录像无音轨、开启并授权后有声音；拒绝麦克风不妨碍无声录像。

### 出口合规及按需项目

- [ ] 核查最终包及依赖的加密行为与 `ITSAppUsesNonExemptEncryption = false` 一致，即不使用非豁免加密。若 ASC 仍要求补充信息，按实际加密用途逐题回答；不要把该值误读为完全不使用任何加密。[Apple 出口合规说明](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- [ ] 当前无追踪/广告/内购实现，ATT、广告标识符、广告 SDK 合规和恢复购买均标为“不适用”。若以后引入相关功能，再核查 ATT 的实际触发条件、隐私申报、广告内容和内购/恢复流程；不因使用相机就申请 ATT。

### App 图标与打包资源

仓库现有 [AppIcon 资源](../JiangJing/Resources/Assets.xcassets/AppIcon.appiconset)引用 `AppIcon-1024.png`，文件为 1024×1024、8-bit RGB PNG，无透明通道；工程将 App Icon 名设为 `AppIcon`。这只证明源资源状态，不证明最终包已验收。

- [ ] 按当前 Xcode 资源目录要求核对 1024×1024 方形原图，无透明通道、不预先绘制系统圆角；确认品牌及素材使用权。上传时复核 [Apple 图标说明](https://developer.apple.com/help/app-store-connect/manage-app-information/add-an-app-icon/)。
- [ ] 从实际产物核对 `Assets.car`、`CFBundleIcons` 中的 `CFBundleIconName`、图标及中英文本地化资源。现有 [verify-app.py](../scripts/verify-app.py) 用于部分产物检查，仍需人工检查图像效果。
- [ ] 真机检查主屏幕、设置、TestFlight 和 ASC 中的图标显示，确认无缺失、错误裁切或不可辨识文字。

### Codemagic 签名前置条件

配置依据：[codemagic.yaml](../codemagic.yaml)。以下分别核对，变量存在不代表签名材料或上传权限已就绪；文档和日志不得填写私钥或凭据。

| 类别 | 待核对内容 |
| --- | --- |
| CI 输入 | `jiangjing_release` 中的 `APP_STORE_APPLE_ID`、两个政策网址；CI 提供的 `PROJECT_BUILD_NUMBER` |
| 团队与集成 | Team `G7LL8HDN83`；集成 `stl2stp-app-store-connect` 指向预期团队 |
| 证书 | 有效 Apple Distribution 证书及配套私钥，Codemagic 可使用 |
| 描述文件 | App Store distribution profile，覆盖 `com.jiangjing.magnifier`，团队、证书及有效期正确 |
| ASC 权限与记录 | 认证有上传所需权限；应用记录存在且 Bundle ID、团队、数字 Apple ID 正确 |

- [ ] 独立核实以上各项并记录结果，按 [Codemagic 配置步骤](codemagic.md)检查签名设置。
- [ ] 明确 `APP_STORE_APPLE_ID` 在当前工作流中只做数字格式检查；实际上传目标由 IPA 的 Bundle ID 与认证团队决定，格式通过不能证明目标正确。
- [ ] 上传前核对最终包版本、构建号和签名；保留提交号、工具版本、archive（含 dSYM）、IPA 与日志，便于定位问题。

## 二、TestFlight 内部测试

- [ ] 先检查对应提交的 `ios-simulator` 测试、Debug 模拟器及 Release 设备无签名构建、产物检查记录；解释所有并发诊断。模拟器成功不能证明相机硬件通过，也不能代替 iOS 16 真机验证。按 [实施与验收记录](implementation-validation.md)补齐未完成验收。
- [ ] 用 iOS 16 及当前系统真机完成：首次授权/拒绝与恢复、实时预览、双指/滑杆/快捷倍数缩放、双击回到 1×、轻点对焦、补光档位、拍照冻结/继续查看、录音开关、录像开始/停止、相册保存及系统分享。
- [ ] 验证“本机媒体”的重试保存、结果未知时的重复保存提示、文件核验、分享及确认丢弃；关闭结果界面不删除文件，丢弃本机副本不删除相册副本。确认中断、前后台切换及重启后的行为，未封装视频不承诺可恢复。
- [ ] 上述条件、真实政策网址和签名材料齐备后，在独立发布操作中手动启动 `ios-testflight`。它会上传 ASC；`submit_to_testflight: false` 关闭自动提交 Beta 审核，`submit_to_app_store: false` 关闭自动提交商店审核，二者均不禁止上传。[Codemagic 发布语义](https://docs.codemagic.io/yaml-publishing/app-store-connect/)
- [ ] 等待 Apple 处理完成；如有错误，检查处理状态和邮件。补齐测试信息、反馈邮箱、按页面要求填写的审核联系信息及出口合规；无需登录。What to Test 可填写“验证后置相机放大、对焦、补光、拍照/录像、保存、分享及本机媒体恢复”。
- [ ] 在 ASC → 应用 → TestFlight → Internal Testing 组中，按本项目约定手动添加本次 build，并添加有相应应用访问权限的 ASC 内部测试员（最多 100 人；资格及角色以 [Apple 内部测试说明](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/) 为准）。具体操作继续维护在 [codemagic.md](codemagic.md)。
- [ ] 测试员在实体 iPhone 的 TestFlight 接受邀请、安装正确版本/构建号，复做采集、音轨、保存和分享冒烟测试，检查中英文政策链接并记录结果。上传成功不等于安装验收通过。

当前 Codemagic 流程只用于内部测试；外部测试和正式送审另行人工安排。

## 三、App Store 送审前

- [ ] 依据 [中英文商店文案](store-copy.md)核对最终包功能，替换占位内容、复查字符/字节限制；首版 `1.0.0` 没有“此版本的更新内容”字段，后续版本按实际变更填写。
- [ ] 为中英文准备真实竖屏 iPhone 截图，展示放大预览、补光、拍照冻结及本机媒体等实际界面。每个所需设备尺寸可提交 1–10 张 JPEG/PNG，无 alpha/透明通道；仅使用获准展示的内容，不暴露客户或个人信息。[Apple 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [ ] 上传时按 ASC 当时的必需槽位和实时规格核对像素尺寸、方向、语言及缩放预览；此处不固定完整像素表或显示尺寸名称。当前为 iPhone 应用，不自行承诺 iPad 界面；若支持平台变化需重查要求。
- [ ] 填写含真实联系方式的支持页面 URL、版权主体及年份，并确认名称可用、发布主体、价格、发行地区和所选地区适用的发布要求。政策 URL 和支持 URL 各司其职，不能留示例地址。
- [ ] 在 ASC 核实主语言及主/次类别。仓库已有 `zh-Hans` 开发语言及 `public.app-category.photography`，不表示 ASC 已自动设置为简体中文或摄影类别。
- [ ] 按实际内容完成年龄分级问卷，复核 App Privacy、政策、出口合规及其他适用的 ASC 必填项；不预填未经确认的年龄等级或发行承诺。
- [ ] 填写 App Review 联系人、电话及邮箱，备注说明：核心功能需要实体 iPhone 的后置相机；无需账号登录；录音可选；相册只请求添加权限。审核步骤可说明放大、拍照/录像及本机媒体入口。
- [ ] 选择验收通过的正确构建，复查全部材料及发布方式后，由负责人另行人工提交 App Store 审核。内部测试通过不会自动送审或上架。

## 内部参考来源

方法论借鉴，已按本项目改写。只读内部资料根目录为 `/home/xai/agent-inputs/flutter-agent-refs/skills/`，本次实际查阅：

- `flutter-quality-gates/references/stage11-compliance.md`：按权限、隐私及实际使用功能逐项检查。
- `flutter-quality-gates/references/stage13-deploy.md`：分开核对签名、版本、发布材料及政策备份。
- `flutter-publishing/references/store-copy.md`：按语言组织字段、依据真实功能复核文案。
- `flutter-icon-workflow/SKILL.md`、`flutter-icon-workflow/references/icon-workflow.md`：资源来源、引用与最终包验收思路。

未迁入 Flutter 工程命令、Android/广告包配置、协议禁止外链规则或 SVG 组件流水线；商店限制以文中 Apple 官方链接及上传时 ASC 要求为准。
