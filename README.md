# AlpacaMusic

[English](#english) · [简体中文](#简体中文)

<a id="english"></a>

## English

A native macOS music player for local and online libraries, immersive visuals, and animated lyrics.

Created by [byalpaca](https://byalpaca.dev) (Junpei Tang). **macOS 26 or later.** Windows is not currently supported.

[Download the latest release](https://github.com/tangyunpei/AlpacaMusic/releases/latest)

[Disclaimer](DISCLAIMER.md#english) · [MIT License](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md#english) · [Security policy](SECURITY.md#english)

### Features

- Local files, folders, HTTP/HTTPS audio links, favorites, playlists, search, and a mixed-source queue.
- Album-art point clouds, orbital particles, flowing ribbons, oscilloscopes, and a segmented spectrum display. Audio-reactive effects use real samples when available.
- Scrolling lyrics and animated captions with selective word and character emphasis: character-by-character Chinese and word-by-word English, Spanish, and similar languages. Missing word timestamps are estimated.
- Saved library and playback position; three original demo tracks to try without an online account.

### Quick start

1. Open the DMG, drag **AlpacaMusic.app** into **Applications**, and launch it.
2. Use **Import (导入)** or drag in local music. Open **Sources (音源)** to connect an online account.
3. Choose a song, then open lyrics (歌词), immersive mode (沉浸模式), or the queue (播放队列) from the player controls.

See [account connections](docs/account-connections.md) for login and playlist import details. The current app UI is in Chinese; advanced technical guides are mainly in Chinese.

### Online sources

| Source | Connection and current limits |
| --- | --- |
| NetEase Cloud Music | Scan with the NetEase Music app, or use the embedded official web login. Search, import, and playback depend on account and track permissions. |
| QQ Music | Scan with QQ or WeChat, or use the embedded official web login. Search, import, and playback depend on account and track permissions. |
| Apple Music | MusicKit authorization, search, personal library/playlist import, and playback. Requires [developer configuration](docs/apple-music-setup.md), user permission, a valid subscription, and track playback rights. |
| Spotify | Official PKCE login, search, playlist/saved-track import, and remote playback control. Requires your own [Client ID and callback configuration](docs/official-platforms.md#spotify配置与播放); playback needs [Premium and an available official device](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback). Real-account testing is still pending. |
| Soda Music | The experimental entry is hidden. See the [research notes](docs/soda-thirdparty-integration-2026-10-03.md). |

NetEase and QQ use web-protocol adapters rather than a stable official third-party SDK. No separate compatibility server is required; custom services remain an advanced option. Tested accounts do not establish availability for every account, region, subscription, or track.

This implementation does not obtain Apple Music or Spotify PCM samples, so their playback cannot drive a real waveform or spectrum. Volume is controlled by the system or official playback device. Apple Music's automatic LRCLIB lyric matching is enabled by default and can be turned off in the lyric menu; queries send track metadata without platform login credentials. See the [data boundaries](DISCLAIMER.md#english).

### Build from source

Requires **Xcode 27, the macOS 27 SDK, and Swift 6.4**. Open `Package.swift` in Xcode, or run:

```sh
./scripts/build-app.sh
open build/AlpacaMusic.app
```

The build targets the current Mac architecture. Local signing is read from the ignored `signing.local.plist`; without it, the build uses ad-hoc signing. Apple Music needs the [MusicKit signing setup](docs/apple-music-setup.md). Distribution requires appropriate Developer ID signing, notarization, and device validation.

### Automatic build version

Each successful release build increments the third component of `CFBundleShortVersionString` and the separate `CFBundleVersion`; edit the first two version components manually. Debug builds (`CONFIGURATION=debug`), tests, and API checks do not increment them. Failed builds do not consume a version; interrupted publication preserves recovery files.

### Shortcuts

| Action | Shortcut |
| --- | --- |
| Import files / folder | ⌘O / ⇧⌘O |
| Search | ⌘K, then Return |
| Play / pause | Space, outside text input |
| Previous / next | ⌘← / ⌘→ |
| Mute / lyrics | ⇧⌘M / ⇧⌘L |
| Immersive mode | ⇧⌘I; Esc exits |
| Playback queue | ⇧⌘Q |
| Point-cloud view | Drag to rotate, scroll/pinch to zoom, double-click to reset |

### Verification

Run `swift test`, `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`, and `./scripts/check-sdk-apis.sh`. See [API compatibility](docs/api-compatibility.md) and [verification records](docs/verification.md) for scope and limitations. The historical `prototype/point-cloud-mode.html` is a design reference and is not loaded by the native app.

### License

Original code, documentation, and project-owned resources that the project has the right to license are provided under the [MIT License](LICENSE). It permits use, copying, modification, merging, publication, distribution, sublicensing, and sale, including commercial use. Copies or substantial portions of the software must retain the copyright and permission notices. See the complete license for its terms; this README and the disclaimer do not add “learning only” or “non-commercial only” restrictions.

Copyright attribution is **Junpei Tang (byalpaca)** and **AlpacaMusic contributors**, as recorded in `LICENSE`. The [Chinese MIT translation](LICENSE.zh-CN.md) is for reference; the English `LICENSE` governs.

Third-party code, assets, system components, and service content retain their respective licenses and rights. A research citation does not permit GPL/AGPL code to be redistributed under this project's MIT License. If you redistribute the historical web prototype, retain its Three.js copyright and full MIT license notices. Review the [Third-party notices](THIRD_PARTY_NOTICES.md#english) when reusing or redistributing materials, and update those notices when adding dependencies or assets.

### Disclaimer and use boundaries

- **Independent project.** AlpacaMusic is not an official client of Apple, Spotify, NetEase Cloud Music, QQ Music, or Soda Music, and does not claim platform partnership, sponsorship, or endorsement. Names and marks identify sources and compatibility; their rights remain with their respective owners.
- **Content rights.** The software license does not grant rights to third-party recordings, compositions, lyrics, translations, artwork, artist images, platform data, or trademarks. Searching, importing, caching, or displaying them does not grant permission to download, redistribute, publicly perform, commercially exploit, or train models on them. Use only content, accounts, files, and services you are entitled to access. Importing an online playlist saves metadata and references, not ownership of audio or permanent playback rights.
- **Platform authorization.** An API being official, a developer account, successful login, or Apple signing/notarization does not establish platform approval of this app's features or distribution. Platform agreements apply separately from MIT. Spotify's policy prohibits integrating streams or content from another service and synchronizing recordings with visual media, and places restrictions on commercial use; existing technical features do not demonstrate permission. Review the [Spotify Developer Policy](https://developer.spotify.com/policy), [Developer Terms](https://developer.spotify.com/terms), and applicable [Apple agreements](https://developer.apple.com/support/terms/) before public distribution or commercial operation.
- **Account and service limits.** Login or a subscription does not guarantee every track, region, or playback method. Availability depends on licensing, account permissions, devices, networks, quotas, and protocol changes; an official client playing a track does not guarantee third-party playback. The app does not unlock memberships or bypass DRM, payment restrictions, regional restrictions, or security verification. NetEase and QQ web interfaces may change or stop working; experimental features and tested accounts do not establish general availability.
- **Data and credentials.** Saved NetEase/QQ sessions and Spotify tokens use the local Keychain; Apple Music authorization is managed by the system and MusicKit. Library data, playlists, favorites, playback position, lyrics, and some caches are stored locally. Online sources, artwork, login, and lyrics services receive network requests. Signing out currently leaves imported track metadata and playlists; platform-side revocation is separate. Spotify requires deletion and cessation of processing of personal data on disconnect, so this retention behavior must be addressed before claiming compliance with that policy. See the [policy's data requirements](https://developer.spotify.com/policy) and the [full data-handling details](DISCLAIMER.md#english). Custom services have their own operators and terms; native-source credentials are not automatically forwarded to them as a fallback. Keep passwords, cookies, tokens, signing configurations, and private keys out of source control and public reports.
- **Lyrics and visuals.** Apple Music's automatic LRCLIB matching is enabled by default and can be disabled in the lyric menu. It sends the title, artist, album, and duration without platform login cookies or Spotify tokens. Matches may use a different recording, and word/character timing may be estimated from line timestamps. This implementation has no Apple Music/Spotify PCM access for a real waveform or spectrum; visual effects and estimated lyrics are not evidence of precise audio analysis.

The software is provided under MIT's “as is” terms. To the extent permitted by applicable law, there is no warranty of merchantability, fitness for a particular purpose, noninfringement, accuracy, security, or uninterrupted availability; liability limits are governed by [LICENSE](LICENSE). These statements do not exclude rights or liabilities that applicable law does not allow to be excluded. A disclaimer cannot replace content permission or platform authorization, or make unauthorized conduct lawful.

Read the complete [Disclaimer](DISCLAIMER.md#english) and [Third-party notices](THIRD_PARTY_NOTICES.md#english) before redistribution. Report attribution omissions, content-rights concerns, or inaccurate statements through the Issues feature of the repository where the project is published, or the public contact details of [byalpaca](https://byalpaca.dev). Identify the material and requested correction without sharing sensitive account information.

---

<a id="简体中文"></a>

## 简体中文

macOS 原生音乐播放器，统一管理本地与在线曲库，提供沉浸式视觉、滚动歌词和动态字幕。

创作者：[byalpaca](https://byalpaca.dev)（Junpei Tang）。**支持 macOS 26 及以上。** 当前不支持 Windows。

[下载最新版本](https://github.com/tangyunpei/AlpacaMusic/releases/latest)

[使用边界与免责声明](DISCLAIMER.md#简体中文) · [MIT License](LICENSE) · [第三方声明](THIRD_PARTY_NOTICES.md#简体中文) · [安全政策](SECURITY.md#简体中文)

### 功能

- 本地文件、文件夹、HTTP/HTTPS 音频链接，以及收藏、歌单、搜索和混合来源队列。
- 封面点云、轨道粒子、流光绸缎、示波器和分段竖条频谱；有可用采样时以真实音频驱动。
- 滚动歌词、动态字幕和局部强调：中文逐字，英语、西语等逐词出现；缺少逐词时间时使用估算。
- 保存曲库和播放位置；内置三首原创试听，无需在线账号即可体验。

### 快速使用

1. 打开 DMG，把 **AlpacaMusic.app** 拖入 **Applications（应用程序）**，然后启动。
2. 点 **导入** 或直接拖入本地音乐；在 **音源** 中连接在线账号。
3. 选择歌曲，通过底部播放器打开歌词、沉浸模式或播放队列。

登录和导入歌单的详细步骤见[账号连接说明](docs/account-connections.md)。当前应用界面为中文，进阶技术文档也以中文为主。

### 在线音源

| 音源 | 连接方式与当前限制 |
| --- | --- |
| 网易云音乐 | 使用网易云音乐 App 扫码，或应用内官方网页登录；搜索、导入和播放取决于账号及曲目权限。 |
| QQ 音乐 | 使用 QQ 或微信扫码，或应用内官方网页登录；搜索、导入和播放取决于账号及曲目权限。 |
| Apple Music | MusicKit 授权、搜索、个人曲库／歌单导入和播放；需要完成[开发者配置](docs/apple-music-setup.md)、用户授权，并具备有效订阅及曲目播放权限。 |
| Spotify | 官方 PKCE 登录、搜索、歌单／喜欢歌曲导入和远程播放控制；需要自己的 [Client ID 与回调配置](docs/official-platforms.md#spotify配置与播放)，播放需要 [Premium 和可用的官方设备](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback)。真实账号联调尚未完成。 |
| 汽水音乐 | 实验入口暂时隐藏，见[调研记录](docs/soda-thirdparty-integration-2026-10-03.md)。 |

网易云与 QQ 使用网页协议适配，并非稳定的官方第三方 SDK；无需另行部署兼容服务，自定义服务保留为高级选项。已有账号实测不代表所有账号、地区、订阅和歌曲均可用。

当前实现无法取得 Apple Music 和 Spotify 的 PCM 采样，因此不能用其播放驱动真实示波器或频谱；音量由系统或官方播放设备控制。Apple Music 的 LRCLIB 自动歌词匹配默认开启，可在歌词菜单关闭；查询会发送歌曲资料，不附带平台登录凭证。详见[数据处理边界](DISCLAIMER.md#简体中文)。

### 从源码构建

需要 **Xcode 27、macOS 27 SDK 和 Swift 6.4**。用 Xcode 打开 `Package.swift`，或运行：

```sh
./scripts/build-app.sh
open build/AlpacaMusic.app
```

构建生成当前 Mac 架构的应用。签名读取已被忽略的本机 `signing.local.plist`；未配置时使用 ad-hoc。Apple Music 需要[配置 MusicKit 与签名](docs/apple-music-setup.md)。对外分发还需正确的 Developer ID 签名、公证及设备验证。

### 自动构建版本

每次成功的正式构建将 `CFBundleShortVersionString` 第三段和独立的 `CFBundleVersion` 各加 1；前两段由维护者手动修改。调试构建（`CONFIGURATION=debug`）、测试和 API 检查不递增。失败不消耗版本号；发布中断时保留恢复文件。

### 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 导入文件／文件夹 | ⌘O / ⇧⌘O |
| 搜索 | ⌘K，输入后回车 |
| 播放／暂停 | 空格，未在输入文字时 |
| 上一首／下一首 | ⌘← / ⌘→ |
| 静音／歌词 | ⇧⌘M / ⇧⌘L |
| 沉浸模式 | ⇧⌘I；Esc 退出 |
| 播放队列 | ⇧⌘Q |
| 点云交互 | 拖动旋转，滚动／捏合缩放，双击归位 |

### 验证

运行 `swift test`、`python3 -m unittest discover -s scripts/tests -p 'test_*.py'` 和 `./scripts/check-sdk-apis.sh`。检查范围与限制见 [API 兼容性](docs/api-compatibility.md)和[验证记录](docs/verification.md)。`prototype/point-cloud-mode.html` 仅作历史设计参考，不由原生应用加载。

### 开源许可

本项目有权许可的原创代码、文档及自有资源采用 [MIT 许可](LICENSE)，允许使用、复制、修改、合并、发表、分发、再许可和销售，包括商业用途。软件的所有副本或实质性部分均须包含版权声明和许可声明。完整条件以许可原文为准；本 README 和免责声明不额外增加“仅供学习”或“禁止商用”等限制。

版权署名为 **Junpei Tang（byalpaca）**及 **AlpacaMusic contributors（项目贡献者）**，以 `LICENSE` 中的记录为准。[MIT 中文译文](LICENSE.zh-CN.md)仅供参考，以英文 `LICENSE` 为准。

第三方代码、素材、系统组件和服务内容仍适用各自的许可及权利条件。列为研究参考，不代表可以把 GPL／AGPL 代码改按本项目的 MIT 许可分发。若分发历史网页原型，须保留其中的 Three.js 版权声明及完整 MIT 许可。复用或分发材料前请核对[第三方声明](THIRD_PARTY_NOTICES.md#简体中文)，新增依赖或素材时也应同步更新。

### 免责声明与使用边界

- **独立项目。** AlpacaMusic 不是 Apple、Spotify、网易云音乐、QQ 音乐或汽水音乐的官方客户端，不声称获得平台合作授权、赞助或背书。名称和标识用于说明音源与兼容性，相关权利归各自权利人所有。
- **内容权利。** 软件许可不授予第三方录音、词曲、歌词、翻译、封面、艺人图片、平台资料或商标的使用权。搜索、导入、缓存或显示内容，不等于取得下载、再分发、公开表演、商业利用或训练模型的授权。请仅使用本人有权访问的内容、账号、文件和服务。导入在线歌单保存的是资料和引用，不等于拥有歌曲音频或永久播放权。
- **平台授权。** 官方接口、开发者账号、登录成功或通过 Apple 签名／公证，均不证明平台已批准本应用的功能或分发。平台协议独立于 MIT 许可适用。Spotify 政策禁止集成其他服务的音频流或内容、将录音与视觉媒体同步，并限制商业用途；已有技术功能不代表已获许可。公开分发或商业运营前，应核对 [Spotify Developer Policy](https://developer.spotify.com/policy)、[Developer Terms](https://developer.spotify.com/terms) 及适用的 [Apple 协议](https://developer.apple.com/support/terms/)。
- **账号与服务限制。** 登录或订阅不保证每首歌、每个地区或每种播放方式都可用。可用性受内容授权、账号权限、设备、网络、配额和协议变更影响；官方客户端可以播放，不保证第三方也能播放。应用不提供会员解锁、绕过 DRM、付费限制、地区限制或安全验证的功能。网易云和 QQ 网页接口可能变更或停止工作，实验功能与已有账号实测不代表普遍可用。
- **数据与凭据。** 网易云／QQ 保存会话和 Spotify 令牌使用本机钥匙串；Apple Music 授权由系统与 MusicKit 管理。曲库、歌单、收藏、播放位置、歌词及部分缓存保存在本机；在线音源、封面、登录和歌词服务会接收网络请求。当前退出账号仍保留已导入的曲目资料与歌单，平台侧撤销授权需另行处理。Spotify 要求断开连接后删除并停止处理个人数据，因此在声称符合该政策前，还需处理这一留存行为。参见[平台数据要求](https://developer.spotify.com/policy)和[完整数据处理说明](DISCLAIMER.md#简体中文)。自定义服务适用其运营方的规则，原生音源凭据不会作为失败回退自动转交给它们。请勿将密码、Cookie、令牌、签名配置或私钥提交到源码仓库或公开反馈。
- **歌词与视觉。** Apple Music 的 LRCLIB 自动匹配默认开启，可在歌词菜单关闭；查询发送歌名、歌手、专辑和时长，不附带平台登录 Cookie 或 Spotify 令牌。结果可能对应不同录音版本，逐词／逐字时间可能根据整句时间估算。当前实现不能取得 Apple Music／Spotify 的 PCM 来生成真实波形或频谱；视觉效果与估算歌词不代表精确的音频分析结果。

软件按 MIT 的“按原样”条款提供。在适用法律允许的范围内，不对适销性、特定用途适用性、不侵权、准确性、安全性或持续可用性作出担保，责任限制以 [LICENSE](LICENSE) 为准。这些说明不排除适用法律规定不得排除的权利或责任。免责声明不能替代内容许可与平台授权，也不会使未经授权的行为自动合法。

分发前请阅读完整的[免责声明](DISCLAIMER.md#简体中文)和[第三方声明](THIRD_PARTY_NOTICES.md#简体中文)。归属遗漏、内容权利问题或不准确的说明，可通过项目实际发布仓库的 Issue 或 [byalpaca](https://byalpaca.dev) 的公开联系方式反馈；请注明相关材料与希望更正的事项，不要公开敏感账号信息。
