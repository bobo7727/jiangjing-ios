# Codemagic → TestFlight

仓库根目录的 `codemagic.yaml` 有两个**手动**工作流，没有 push 自动触发。编译检查不得使用会上传的 `ios-testflight`。Xcode 固定为 **26.6**，机器是 `mac_mini_m2`，和 stl2stp 相同。营销版本保持 `1.0.0`；构建号用 Codemagic 的 `PROJECT_BUILD_NUMBER`，不写死在仓库里。

| 工作流 | 名称 | 做什么 | 签名 |
| --- | --- | --- | --- |
| `ios-simulator` | iOS simulator - compile check | 运行纯逻辑与 iOS 集成测试，编译不签名 Debug 模拟器和 Release 设备目标，检查资源并保留日志 | 不需要 |
| `ios-testflight` | iOS signed release - TestFlight | 签名 Release IPA，提交 TestFlight，不提交 App Store 审核 | 需要下面的 Apple 与 Codemagic 配置 |

XcodeGen 固定为 2.44.1，由 `scripts/install-xcodegen.sh` 从官方 GitHub release 安装到 checkout 的 `build/tools`，使用发布附件的 SHA-256 校验。来源：[发布附件与摘要](https://github.com/yonaskolb/XcodeGen/releases/expanded_assets/2.44.1)。Xcode、Swift、XcodeGen 版本和提交号作为 artifacts 保留。

Bundle ID 固定为 `com.jiangjing.magnifier`。Team ID 为 `G7LL8HDN83`。`Info.plist` 里 `ITSAppUsesNonExemptEncryption` 为 false。`JiangJing/PrivacyInfo.xcprivacy` 声明不追踪、不收集数据。共享 scheme 在 `JiangJing.xcodeproj/xcshareddata/xcschemes/JiangJing.xcscheme`。

Codemagic 应连接 GitHub 仓库 [bobo7727/jiangjing-ios](https://github.com/bobo7727/jiangjing-ios)，和 stl2stp 一样走 GitHub。Cursor Origin 仍是开发远程，不要改它的地址。

## 1. 把仓库接到 Codemagic

用自己的 Codemagic 账号登录，安装并授权 GitHub 集成，选中私有仓库 **bobo7727/jiangjing-ios**。工作流文件用仓库根的 `codemagic.yaml`，分支选 `main`。私有仓库要把 Codemagic 的 GitHub 应用加进该仓库的访问权限。不要把本机的个人 SSH 私钥交给 Codemagic。

密钥和 API 私钥只放在 Codemagic，不写进 YAML，不提交 Git。

先按下面的通知设置创建 `grokbot_notify` 组，再手动启动 `ios-simulator`。必须检查测试结果及完整并发诊断；不可将未解释的并发告警视为验收通过。zip 不能装到 iPhone，当前可用模拟器 runtime 的测试也不代表已运行 iOS 16。真机验收通过并补齐发布条件后，再单独启动 `ios-testflight`。

## 2. 在 Apple 侧登记应用

1. 打开 [Apple Developer](https://developer.apple.com/account/resources/identifiers/list) → Identifiers，注册 App ID，Bundle ID 填 **`com.jiangjing.magnifier`**（Explicit）。勾选相机相关能力不必额外开；这个应用只用系统相机、麦克风和“添加到相册”。
2. 打开 [App Store Connect](https://appstoreconnect.apple.com/apps) → App → 新建。平台选 iOS，Bundle ID 选刚注册的 `com.jiangjing.magnifier`，名称可用「匠镜」。
3. 打开该 App 的 **App Information**，记下 **Apple ID（一串数字）**。这不是 Bundle ID，也不是 Team ID `G7LL8HDN83`，也不是登录邮箱。
4. 发布工作流复用已有的 Codemagic App Store Connect 集成，名字必须是：

```text
stl2stp-app-store-connect
```

不要把 Issuer ID、Key ID 或 `.p8` 写进仓库。签名证书和 App Store 描述文件在 Codemagic 的 Team settings → codemagic.yaml settings → Code signing identities 里，用这个集成按 Bundle ID 取或生成 Apple Distribution 证书和 App Store profile。YAML 里写了 `bundle_identifier` 并不等于证书已经就绪。说明见 [Codemagic iOS 签名](https://docs.codemagic.io/yaml-code-signing/signing-ios/)。

## 3. 填 TestFlight 测试信息

第一次上传后，Apple 可能报 **post-processing failed** 或卡在 “Missing Compliance”。在 App Store Connect 里打开这个 App 的 TestFlight，把测试信息填全，再等处理：

- **Test Information**：反馈邮箱；Beta App Review Information 里的名、姓、电话、邮箱。本应用没有登录账号，Sign-in required 选 No。
- **What to Test**：写一两句即可，例如用后置相机放大、拍照和录像。
- **出口合规**：选“否”，应用不使用非豁免加密。这和 `Info.plist` 里的 `ITSAppUsesNonExemptEncryption = false` 一致。若构建旁仍出现合规按钮，也选否。

联系方式用你自己的，不要留空。

## 4. 配置变量组并启动发布

在 Codemagic 的 Team settings → Global variables and secrets 新建组 **`jiangjing_release`**，添加：

| 变量 | 值 |
| --- | --- |
| `APP_STORE_APPLE_ID` | 第 2 步记下的数字 Apple ID |
| `PRIVACY_POLICY_URL_ZH` | 已公开可访问的中文 HTTPS 隐私政策网址 |
| `PRIVACY_POLICY_URL_EN` | 已公开可访问的英文 HTTPS 隐私政策网址 |

`ios-testflight` 已经引用这个组。缺变量、Apple ID 不是纯数字，或政策网页无法公开访问时，工作流会在签名之前失败。`APP_STORE_APPLE_ID` 只校验格式，实际上传目标仍由 IPA 的 Bundle ID 和认证团队决定，必须在 App Store Connect 人工核对应用记录。

`docs/privacy/zh.html` 和 `en.html` 是与应用内文案一致的待发布页面。发布者需核对主体及联系方式、实际行为后发布，并将网址填入变量组及 App Store Connect；本次没有托管、发布或验证真实网址。校验脚本只检查 HTTPS 响应及页面标识，不认证政策完整性。真实政策是分发门槛。

选含 `codemagic.yaml` 的最新提交，手动启动 **`ios-testflight`**。它会先校验公开政策网址并写入本次构建的 Info.plist，再安装固定版本 XcodeGen、按 `project.yml` 生成工程、执行 `xcode-project use-profiles`、用 `agvtool new-version -all` 写入 `PROJECT_BUILD_NUMBER`，再打 IPA 并提交 TestFlight。`submit_to_app_store` 为 false，不会送审上架。

上传成功只表示文件到了 App Store Connect。还要等 Apple 处理完，并在 TestFlight 里加测试员。正式上架不在这条工作流里。

## 5. 失败时看哪里

- 模拟器工作流失败：看 Xcode 编译日志，先确认 Xcode 是 26.6、scheme 名是 `JiangJing`。
- 签名失败：核对 Bundle ID、Team `G7LL8HDN83`、集成名 `stl2stp-app-store-connect`，以及 App Store profile 是否覆盖 `com.jiangjing.magnifier`。
- `APP_STORE_APPLE_ID` 报错：变量组名必须是 `jiangjing_release`，值只能是数字。
- 政策校验报错：提供真实公开 HTTPS 页面；不要用示例网址或需要登录的页面。
- `agvtool` 报项目没有版本管理：`project.yml` 里已设 `VERSIONING_SYSTEM: apple-generic`。确认生成步骤在 `agvtool` 之前。
- TestFlight 处理失败：回到第 3 步把测试信息和出口合规填完，然后等 Apple 重试，不必为了这个改代码。

参考：[App Store Connect 发布](https://docs.codemagic.io/yaml-publishing/app-store-connect/)、[YAML 基础配置](https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/)。

这份配置要在 Codemagic 的 Mac 上跑过才能确认签名和 TestFlight。这里没有 Xcode，不能代替那一步。

## Grok Bot 构建完成通知

**启用本 YAML 的任何工作流之前**，bobo 需在 Codemagic → Team settings → Global variables and secrets 创建 **`grokbot_notify`**，授权此 App 使用，并添加以下两个变量，两项都勾选 **Secret**：

| 变量 | 内容 |
| --- | --- |
| `GROKBOT_WEBHOOK_URL` | Grok Bot routine 的完整 HTTPS webhook URL，不带用户信息或 fragment |
| `GROKBOT_WEBHOOK_KEY` | webhook 的 Bearer key |

两个工作流都引用该组；只有 TestFlight 继续引用已有的 `jiangjing_release`。组必须先创建：变量组由 Codemagic 在执行脚本前解析，不应依赖不存在的组被忽略；官方文档未承诺这种回退，脚本也不能捕获配置阶段错误。组已存在但任一通知变量未注入、为空（去除 CR/LF 后），或 URL 无效时，通知静默跳过。详见 [变量组与 Secret 配置](https://docs.codemagic.io/yaml-basic-configuration/configuring-environment-variables/)。

实现使用共享的 `scripts/notify-grokbot.sh` 和每个工作流唯一的 `publishing.scripts`。Codemagic [post-publish 文档](https://docs.codemagic.io/yaml-distributing/post-publish/) 说明该脚本在构建失败后也会执行，但取消或超时会跳过，因此不会发送 `canceled`，也不能保证每次运行都有回调。模拟器仍不签名、不上传；它的 publishing 部分只发送通知。

最后一个普通脚本尽力创建 `$HOME/codemagic-success-$CM_BUILD_ID`（build ID 必须非空），通知只检查当前 build 的标记。标记创建失败不改变构建结果；没有标记保守地视为未确认普通脚本成功。状态约定如下：

| 工作流 | `status` | 含义 |
| --- | --- | --- |
| `ios-simulator` | `success` / `failed` | 当前 build 标记存在 / 不存在，仅表示普通脚本是否完成 |
| `ios-testflight` | 固定 `finished` | 通知钩子已运行；**不表示上传成功或失败**。额外的 `script_marker: present/absent` 也只是普通脚本完成提示 |

CI 不添加 Codemagic API token，也不查询 Codemagic API。接收端收到 TestFlight 通知后自行查询真实上传结果；钩子执行时最终状态也可能尚未就绪，需要由接收端处理。

JSON 包含 `source: codemagic`、`app: jiangjing-ios`、`workflow`、`build_id`、`app_id`、`build_url`（`https://codemagic.io/app/<app_id>/build/<build_id>`）、`status`、`branch`、`commit`、`timestamp`（发送时的 UTC ISO-8601 时间），TestFlight 另有上述 `script_marker`。ID、分支和提交来自 [Codemagic 内置变量](https://docs.codemagic.io/yaml-basic-configuration/environment-variables/)；YAML 不使用仅 Workflow Editor 提供的 `CM_BUILD_STEP_STATUS`。

请求使用 `Authorization: Bearer …` 和 `Content-Type: application/json`。脚本先关闭 tracing，清除 URL/key 中所有 CR/LF，用权限 600 的系统临时文件传给 curl 并清理，不输出 URL、key 或响应。curl 仅允许 HTTPS、不跟随重定向，连接限时 3 秒、单次请求 8 秒、最多重试 2 次，重试窗口 18 秒，进程总限时 30 秒；同一次通知复用完全相同的 JSON。行为依据 [curl 文档](https://curl.se/docs/manpage.html)。通知失败、缺工具或序列化异常都静默返回 0，外层另有 `|| true`，不改变原构建结果。接收端按 **build ID + workflow** 去重，因为重试可能重复投递。

本地检查依赖固定的 `PyYAML==6.0.3`（[发行页](https://pypi.org/project/PyYAML/6.0.3/)），模拟器 CI 在检查前自动安装。运行：

```bash
python3 -m pip install -r scripts/requirements-checks.txt
python3 scripts/check-repository.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py'
```

测试用本地 curl 替身，不会触发真实 webhook。上线仍需在 Codemagic 分别验证成功构建、故意的普通脚本失败、空凭据和 webhook 不可达时的行为；TestFlight 的真实上传结果交由接收端验证。真实发布验证需另行授权。

## 内测分发说明

`codemagic.yaml` 里设为 `submit_to_testflight: false`：Codemagic 只上传到 App Store Connect，不提交外部 Beta 审核（stl2stp 曾因该接口返回 HTTP 422 导致构建被标记失败）。每个新 build 处理完成后（十几分钟到半小时），需要在 App Store Connect 的 TestFlight → Internal Testing 组里手动添加该 build。

## 发布前的独立检查

核对签名证书私钥、profile 的 Bundle ID/团队/有效期、ASC 集成权限、应用记录和递增构建号；本地静态检查无法替代这些验证。
发布工作流保留 `build/ios/archive/*.xcarchive`（含 dSYM）、IPA、archive 日志和工具版本。上传后还需等待 Apple 处理并在内部测试设备安装，完成采集、保存、音轨和分享冒烟测试。
`submit_to_testflight: false` 仍会上传 ASC，只关闭自动 Beta 审核提交，见 [Codemagic 发布说明](https://docs.codemagic.io/yaml-publishing/app-store-connect/)。
