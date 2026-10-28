# Codemagic → TestFlight

仓库根目录的 `codemagic.yaml` 有两个**手动**工作流，没有 push 自动触发。Xcode 固定为 **26.6**，机器是 `mac_mini_m2`，和 stl2stp 相同。营销版本保持 `1.0.0`；构建号用 Codemagic 的 `PROJECT_BUILD_NUMBER`，不写死在仓库里。

| 工作流 | 名称 | 做什么 | 签名 |
| --- | --- | --- | --- |
| `ios-simulator` | iOS simulator - compile check | 用 XcodeGen 生成工程，编一个不签名的模拟器 `.app` 并打成 zip | 不需要 |
| `ios-testflight` | iOS signed release - TestFlight | 签名 Release IPA，提交 TestFlight，不提交 App Store 审核 | 需要下面的 Apple 与 Codemagic 配置 |

Bundle ID 固定为 `com.jiangjing.magnifier`。Team ID 为 `G7LL8HDN83`。`Info.plist` 里 `ITSAppUsesNonExemptEncryption` 为 false。`JiangJing/PrivacyInfo.xcprivacy` 声明不追踪、不收集数据。共享 scheme 在 `JiangJing.xcodeproj/xcshareddata/xcschemes/JiangJing.xcscheme`。

Codemagic 应连接 GitHub 仓库 [bobo7727/jiangjing-ios](https://github.com/bobo7727/jiangjing-ios)，和 stl2stp 一样走 GitHub。Cursor Origin 仍是开发远程，不要改它的地址。

## 1. 把仓库接到 Codemagic

用自己的 Codemagic 账号登录，安装并授权 GitHub 集成，选中私有仓库 **bobo7727/jiangjing-ios**。工作流文件用仓库根的 `codemagic.yaml`，分支选 `main`。私有仓库要把 Codemagic 的 GitHub 应用加进该仓库的访问权限。不要把本机的个人 SSH 私钥交给 Codemagic。

密钥和 API 私钥只放在 Codemagic，不写进 YAML，不提交 Git。

先手动启动 `ios-simulator`。zip 只说明能编译，不能装到 iPhone。通过后再启动 `ios-testflight`。

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

`ios-testflight` 已经引用这个组。缺变量或不是纯数字时，工作流会在签名之前失败。

选含 `codemagic.yaml` 的最新提交，手动启动 **`ios-testflight`**。它会安装 XcodeGen、按 `project.yml` 生成工程、执行 `xcode-project use-profiles`、用 `agvtool new-version -all` 写入 `PROJECT_BUILD_NUMBER`，再打 IPA 并提交 TestFlight。`submit_to_app_store` 为 false，不会送审上架。

上传成功只表示文件到了 App Store Connect。还要等 Apple 处理完，并在 TestFlight 里加测试员。正式上架不在这条工作流里。

## 5. 失败时看哪里

- 模拟器工作流失败：看 Xcode 编译日志，先确认 Xcode 是 26.6、scheme 名是 `JiangJing`。
- 签名失败：核对 Bundle ID、Team `G7LL8HDN83`、集成名 `stl2stp-app-store-connect`，以及 App Store profile 是否覆盖 `com.jiangjing.magnifier`。
- `APP_STORE_APPLE_ID` 报错：变量组名必须是 `jiangjing_release`，值只能是数字。
- `agvtool` 报项目没有版本管理：`project.yml` 里已设 `VERSIONING_SYSTEM: apple-generic`。确认生成步骤在 `agvtool` 之前。
- TestFlight 处理失败：回到第 3 步把测试信息和出口合规填完，然后等 Apple 重试，不必为了这个改代码。

参考：[App Store Connect 发布](https://docs.codemagic.io/yaml-publishing/app-store-connect/)、[YAML 基础配置](https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/)。

这份配置要在 Codemagic 的 Mac 上跑过才能确认签名和 TestFlight。这里没有 Xcode，不能代替那一步。
