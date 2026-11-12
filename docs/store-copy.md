# 匠镜 App Store 商店文案

本页以中文说明填写方式，提供简体中文和英文模板及基于当前实现的初稿。发布前结合 [发布检查清单](release-checklist.md)验收功能、政策与素材，再在 ASC 对应语言中填写。上传操作见 [Codemagic 文档](codemagic.md)。文案初稿不代表名称已可用或应用已经验收通过。

## 字段规则与占位模板

名称、副标题上限均为 30 字符（不是 30 字节）；关键词按 UTF-8 **不超过 100 字节**控制；推广文本上限 170 字符，描述及后续版本更新说明上限 4000 字符。计数包含空格、标点和换行，提交时以 ASC 校验为准。依据：[Apple 应用信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)、[Apple 版本字段规格](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)。

| 字段 | 简体中文占位 | English placeholder | 限制 |
| --- | --- | --- | --- |
| 名称 / Name | `<应用名称>` | `<App name>` | ≤30 字符 |
| 副标题 / Subtitle | `<核心用途与价值>` | `<Core purpose and value>` | ≤30 字符 |
| 关键词 / Keywords | `<相关词一>,<相关词二>` | `<keyword one>,<keyword two>` | UTF-8 ≤100 字节，英文逗号分隔 |
| 推广文本 / Promotional Text | `<当前版本可验证的功能亮点>` | `<Verified current feature highlights>` | ≤170 字符 |
| 描述 / Description | `<用途、实际功能、设备要求与限制>` | `<Purpose, real features, requirements and limits>` | ≤4000 字符，纯文本 |
| 更新说明 / What's New | `<本次已交付且可验证的变更>` | `<Changes delivered and verified in this update>` | 后续版本 ≤4000 字符；首版不适用 |

下方代码块仅包含各字段文本，可单独复制；不复制标题、围栏或计数表。所有尖括号占位需替换后重新计数。关键词不用其他公司/应用名称，不重复应用名称，不堆砌无关词。

## 简体中文初稿

### 名称

```text
匠镜 - 手作放大镜
```

### 副标题

```text
放大细节，拍照录像，随手分享
```

### 关键词

```text
近距观察,细节拍摄,首饰查看,手电补光,微小零件
```

### 推广文本

```text
用 iPhone 查看首饰、线迹和细小零件。双指缩放、轻点对焦，按需补光；拍下照片或录制可选声音的视频，再保存到相册或通过系统分享。
```

### 描述

```text
匠镜把 iPhone 的后置相机变成手作放大镜，方便查看首饰、线迹、模型和细小零件。

放大与对焦
双指缩放、滑杆和快捷倍数让你调整视野；轻点画面对焦，双击回到 1×。最高约 15 倍数字放大，受机型限制；高倍数下画面可能变软，近摄效果依设备而异。

按需补光
使用手电筒弱、中、强三档亮度，也可关闭。补光是否可用取决于设备及其当前状态。

拍照与录像
拍照后冻结画面，方便停下来查看，再继续实时观察。支持录像，可选择是否开启麦克风收录声音。照片按预览比例裁切；录像画幅可能与预览不同。

保存与分享
将照片和视频保存到系统相册，或使用系统分享面板交给你选择的应用与服务。

本机媒体
保留采集文件和保存状态，可重试保存、分享、核验文件或明确丢弃本机副本。关闭结果界面不会删除文件；已保存的本机副本也需自行清理。上次保存结果未知时，重试可能产生重复内容；未封装完成的视频可能无法恢复。

权限与设备
无需登录。相机用于放大、拍照和录像；麦克风仅在开启录音时使用；相册仅请求添加权限。应用不向开发者上传照片、视频或音频；系统相册、iCloud 和所选分享服务可按各自设置同步。

适用于有后置相机的 iPhone，需 iOS 16 或更高版本；当前仅支持竖屏。
```

### 更新说明

`1.0.0` 首版：**不适用（N/A）**，Apple 首版没有此字段。下方仅为后续版本模板，必须替换为实际交付且验证通过的变化，不能把占位作为成稿上传。[Apple 版本字段规格](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)

```text
本次更新：
<填写已验证的功能变化及其使用影响>
<填写已修复的问题及其触发场景；无此项则删除>
```

| 字段 | 字符数 | UTF-8 字节数 | 校验 |
| --- | ---: | ---: | --- |
| 名称 | 10 | 24 | ≤30 字符 |
| 副标题 | 14 | 42 | ≤30 字符 |
| 关键词 | 24 | 64 | ≤100 字节 |
| 推广文本 | 66 | 182 | ≤170 字符 |
| 描述 | 529 | 1474 | ≤4000 字符 |
| 后续更新说明模板（含占位） | 48 | 132 | ≤4000 字符；首版 N/A |

## 英文初稿

### 名称 / Name

```text
JiangJing Magnifier
```

### 副标题 / Subtitle

```text
Zoom in on your craft
```

### 关键词 / Keywords

```text
closeup,stitch,jewelry,inspection,torch,focus,detail,photo,video
```

### 推广文本 / Promotional Text

```text
Inspect fine details with your iPhone. Zoom, tap to focus and add torch light. Capture photos or video with optional sound, then save or share.
```

### 描述 / Description

```text
Turn your iPhone's rear camera into a magnifier for jewelry, stitches, models and small parts.

Zoom and focus
Use pinch gestures, a slider or zoom presets to adjust your view. Tap to focus and double-tap to return to 1x. Digital zoom reaches up to about 15x, subject to device limits. Higher zoom may soften the image, and close-up performance varies by device.

Add light
Choose low, medium or high torch brightness, or switch it off. Availability depends on your device and its current condition.

Capture photos and video
Take a photo to freeze the view, then return to live observation. Record video with optional microphone audio. Photos are cropped to the preview's aspect ratio; video framing may differ from the preview.

Save and share
Save photos and videos to your photo library, or use the system share sheet to send them to an app or service you choose.

On-device media
Keep capture files and save status on your device. Retry saving, share, verify files or explicitly discard local copies. Closing a result does not delete its file; saved local copies also need manual cleanup. Retrying an uncertain save may create duplicates. Videos that were not finalized may be unrecoverable.

Permissions and requirements
No login is required. The camera provides magnification, photos and video. The microphone is used only when you enable audio. Photo library access is add-only. The app does not upload photos, video or audio to the developer. Photos, iCloud and your chosen sharing services may sync content according to their settings.

Requires an iPhone with a rear camera and iOS 16 or later. Portrait orientation only.
```

### 更新说明 / What's New

`1.0.0` 首版：**N/A**。后续版本才使用以下模板，并按真实变更替换或删去各项。

```text
In this update:
<Describe verified feature changes and how they affect use.>
<Describe fixed issues and when they occurred; remove if not applicable.>
```

| 字段 | 字符数 | UTF-8 字节数 | 校验 |
| --- | ---: | ---: | --- |
| 名称 | 19 | 19 | ≤30 字符 |
| 副标题 | 21 | 21 | ≤30 字符 |
| 关键词 | 64 | 64 | ≤100 字节 |
| 推广文本 | 143 | 143 | ≤170 字符 |
| 描述 | 1632 | 1632 | ≤4000 字符 |
| 后续更新说明模板（含占位） | 150 | 150 | ≤4000 字符；首版 N/A |

计数表针对代码块内文本，包含段落间的 LF 换行，不包含围栏前后的换行；更新说明统计的是含占位的后续模板，不是首版成稿。替换占位或修改标点后须重新统计；UTF-8 字节数可用 `len(text.encode("utf-8"))` 复核。

## 功能依据与文案边界

| 文案内容 | 仓库依据 |
| --- | --- |
| 后置相机、变焦上限、对焦、录像与录音开关 | [CameraController](../JiangJing/Camera/CameraController.swift)、[MagnifierConfig](../JiangJing/Support/MagnifierConfig.swift) |
| 缩放手势、双击回到 1×、拍照冻结、滑杆/快捷倍数、补光操作 | [MagnifierScreen](../JiangJing/Features/MagnifierScreen.swift)、[ControlBar](../JiangJing/Features/ControlBar.swift) |
| 相册添加、系统分享、本机媒体保存状态/重试/核验/丢弃 | [PhotoLibrarySaver](../JiangJing/Media/PhotoLibrarySaver.swift)、[ShareSheet](../JiangJing/Features/ShareSheet.swift)、[MediaLibraryView](../JiangJing/Features/MediaLibraryView.swift)、[MediaLibraryModel](../JiangJing/Media/MediaLibraryModel.swift) |
| 权限、本地保留及同步边界、最低系统与竖屏 | [中文资源](../JiangJing/Resources/zh-Hans.lproj/Localizable.strings)、[英文资源](../JiangJing/Resources/en.lproj/Localizable.strings)、[Info.plist](../JiangJing/Info.plist)、[工程描述](../project.yml) |

不要把路线图当作已实现功能：滤镜、网格、曝光/对焦锁定、记忆倍数、可选 4K、应用内媒体回放和横屏均不写入初稿。不要宣传光学 15 倍、固定录像规格、照片与视频都完全匹配预览裁切、特定社交应用专属集成或未经确认的免费/价格承诺。系统分享目标取决于用户设备和已安装服务。

## 内部参考来源

方法论借鉴，已按本项目改写：只读资料 `/home/xai/agent-inputs/flutter-agent-refs/skills/flutter-publishing/references/store-copy.md` 的按语言拆分字段、围绕真实用途写作和逐项自检方法。字段长度及首版规则已改用 Apple App Store 规范，未沿用其他商店的副标题、短描述或标签规格；未大段复制原文。其他合规、部署与图标参考路径见 [发布检查清单](release-checklist.md)。
