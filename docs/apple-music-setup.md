# Apple Music 开发配置

AlpacaMusic 使用 macOS 原生 MusicKit。未配置签名时构建使用 ad-hoc；本机 `signing.local.plist` 可固定开发者签名身份。Apple Music 默认仍显示为尚未配置；本地音乐与其他已配置的来源仍可使用。Apple Developer 会员资格、应用的 MusicKit 服务配置、用户授权、Apple Music 订阅是分别检查的条件。

## 配置 App ID

1. 在自己的 [Apple Developer 账户](https://developer.apple.com/account/resources/identifiers/list)中创建或编辑 **Explicit App ID**。
2. 将 Bundle ID 设为自己团队拥有的明确标识符；项目默认值为 `dev.byalpaca.music`，构建时可以用 `BUNDLE_ID` 覆盖。
3. 在这个 App ID 的 **App Services** 中开启 **MusicKit**，保存。
4. 在自己的开发环境准备匹配团队的 Apple 开发者签名身份。记录 Team ID；不要把签名私钥、密码或 `.p8` 文件提交到仓库。

Apple 将自动生成的 developer token 与应用的 Bundle ID 关联，原生 MusicKit 会为 API 请求管理 token。本接入不需要把媒体服务私钥放进应用，也不自行构造 JWT。[Apple 自动 token 文档](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)、[Apple MusicKit 账户配置](https://developer.apple.com/help/account/services/musickit/)、[Apple 对原生平台的 token 建议](https://developer.apple.com/documentation/applemusicapi/generating-developer-tokens)

**不要添加 `com.apple.developer.musickit`。** Apple DTS 明确说明 MusicKit 是 App ID 服务，并非由专属 entitlement 授权。项目已有 entitlements 只描述可选沙盒的文件和网络访问。[Apple DTS 说明](https://developer.apple.com/forums/thread/784114)

## 构建

需要包含 macOS 27 SDK 和 Swift 6.4 的 Xcode；最低运行系统仍为 macOS 26。当前 SwiftPM 打包流程保留，不需要为此创建另一份 Xcode 工程。

普通本地构建：

```sh
./scripts/build-app.sh
```

该脚本默认是正式构建，成功后自动将 `Info.plist` 的三段版本号最后一段与内部构建编号各加 1；前两段由维护者手动设置。调试构建（`CONFIGURATION=debug`）不递增。候选版本在签名前写入 App，失败不写回源版本；完整规则见 [README 的自动构建版本](../README.md#自动构建版本)。

为保持钥匙串授权在代码更新后仍可识别同一应用，可在项目根目录建立 `signing.local.plist`（已加入 Git 忽略）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>SigningIdentity</key>
    <string>填写本机签名证书的40位十六进制指纹</string>
    <key>TeamIdentifier</key>
    <string>填写对应的10位团队标识</string>
</dict>
</plist>
```

此文件仅保存公开证书指纹和团队标识，不包含密码、私钥或平台会话。普通构建会读取它；配置无效、证书不可用或签名验证失败时终止，保留上次成功的应用，不降级为 ad-hoc。显式传入 `SIGN_IDENTITY` 时忽略本地文件，同时使用传入的 `TEAM_ID`；`SIGN_IDENTITY=-` 可明确选择临时签名。不要频繁切换签名类型、团队或 Bundle ID，因为会改变钥匙串识别的应用身份。

签名本身不启用 MusicKit。已有本机固定签名配置且已为对应 App ID 开启 MusicKit 时，沿用该身份构建：

```sh
env -u SIGN_IDENTITY -u TEAM_ID ENABLE_MUSICKIT=1 ./scripts/build-app.sh
```

这会仅在当前命令中清除可能继承的签名覆盖，不改变终端环境或本地配置。无需为了启用 MusicKit 切换签名类型。构建开关不会代替开发者门户的 App ID 服务配置。

没有本机配置时，使用自己的实际证书指纹和团队执行：

```sh
ENABLE_MUSICKIT=1 \
SIGN_IDENTITY='YOUR_40_CHARACTER_CERTIFICATE_SHA1' \
TEAM_ID='TEAMID1234' \
BUNDLE_ID='com.example.alpacamusic' \
./scripts/build-app.sh
```

示例中的证书指纹、团队和 Bundle ID 都是占位值。`SIGN_IDENTITY` 必须填写已安装证书的实际 40 位指纹，或其完整签名身份名称；不能用 Team ID 自行拼出 `Apple Development: … (…)` 的名称，也不要把显示名中的括号内容直接当作 Team ID。身份来自显式环境变量或本地配置文件，脚本才让系统 `codesign` 使用该身份；系统可能显示正常的钥匙串访问提示。脚本不枚举账户或签名身份，不导出私钥，也不代为登录或修改 Apple 开发者门户。

| 环境变量 | 默认值 | 含义 |
| --- | --- | --- |
| `ENABLE_MUSICKIT` | `0` | `1` 表示开发者已在对应 App ID 上启用 MusicKit，并请求生成可连接构建 |
| `SIGN_IDENTITY` | 本地配置；缺省 `-` | `-` 为 ad-hoc；其他值传给系统签名工具 |
| `TEAM_ID` | 本地配置；缺省空 | 使用开发者身份签名时必填，签名完成后核对真实团队 |
| `BUNDLE_ID` | 源 `Info.plist` 中的值 | 仅修改产物，不修改仓库中的默认标识符 |
| `PROVISIONING_PROFILE` | 空 | 可选：自己提供的 macOS `.provisionprofile` 文件路径 |
| `SANDBOX` | `0` | `1` 使用现有文件访问和网络沙盒配置 |
| `CONFIGURATION` | `release` | 可选 `debug` |

签名后会验证完整性、Apple 证书信任锚、实际签名 Team ID 和 Bundle ID；任一失败不会替换上一次成功的应用。产物为 `build/AlpacaMusic.app`。重建始终重新组装应用，清除上次构建的 MusicKit 标志和 profile。此脚本不进行公证或上传，也不声称开发者签名产物已经满足对外分发流程。

## 可选 provisioning profile

macOS 的所有签名应用并非都需要 profile；使用受限 entitlement 时才有相应要求。MusicKit 本身没有专属 entitlement，因此不要为了 MusicKit 编造一个。已有开发或分发流程提供了 profile 时，可再传入：

```sh
PROVISIONING_PROFILE='/absolute/path/AlpacaMusic.provisionprofile'
```

把该环境变量与上面的签名变量一起传给脚本，而非单独执行。profile 必须由自己的 Apple 开发流程生成；根据开发/分发方式选择正确类型，开发 profile 的设备注册范围仍由 macOS 检查。

脚本将提供的 profile 嵌入 `Contents/embedded.provisionprofile`，检查平台、有效日期、团队、明确的 App ID，以及实际签名证书是否在 profile 的授权列表中。App ID 前缀不被假定为 Team ID。只从 profile 取获准的应用/团队身份 entitlement，不复制全部可选权限。

这些是本地一致性检查；profile 信任和设备资格以 macOS 验证为准。profile 也不能证明 Apple 门户中的 MusicKit 服务已开启。[Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

## 应用内连接与验证边界

`Info.plist` 保留 `NSAppleMusicUsageDescription`。Apple 要求此说明用于用户授权；真正播放还需要检查当前订阅的播放能力。[MusicKit 文档](https://developer.apple.com/documentation/musickit)

本项目的配置门禁同时要求：

- `AlpacaMusicMusicKitConfigured = true`；
- `AlpacaMusicMusicKitTeamIdentifier` 与进程真实签名团队相同；
- 签名不是 ad-hoc，并且存在非空使用说明。

门禁通过只表示构建已明确配置。用户仍需在应用中选择连接并授权；token、账户、网络与订阅错误由连接流程分别报告。拥有 Apple Developer 账户不代表已经拥有可播放的 Apple Music 订阅。

本轮默认 ad-hoc 路径和配置拒绝逻辑可在没有开发者证书的情况下验证；真实团队签名、门户自动 token 和订阅播放必须使用开发者自己的身份及账户实测。项目不内置这些凭据。


## 导入个人曲库

在“音源 → Apple Music”连接成功后，选择“导入我的曲库”：

- “导入全部歌曲”读取个人曲库中的歌曲与专辑曲目；显示专辑名和封面，加入本地“音乐库”，不另建一个替代远端歌单的假歌单。
- 下方“我的歌单”可单独导入；歌单中未加入个人曲库的歌曲也随该歌单导入。
- 请求逐页读取完整结果。读取途中失败或超过本地 10000 首总量限制时给出错误，不把第一页当作完整导入。再次导入合并新歌曲、更新元数据，保留本地收藏、已有歌单名称及本地追加曲目。
- 导入仅保存资料，不下载歌曲音频、不修改 Apple Music 云端曲库或歌单。退出导入窗口会取消尚未提交的操作。
- 个人曲库歌曲保留 Apple 提供的原始资源编号和资源类型，与公开目录编号分别解析播放；编号不依赖 `i.` 等前缀。缺少播放参数的曲目仍保留并显示不可用，不以其他歌曲替代。
- 授权使用系统当前 Apple Music 账户；此入口不是独立的 Apple 账号登录器。切换系统媒体账户后应重新连接并检查订阅。

接口来自官方 MusicKit `MusicDataRequest` 的自动授权请求，使用 Apple Music API 的 `/v1/me/library` 只读资源；不手工提取或保存 Music User Token。[Apple 用户授权说明](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit)
