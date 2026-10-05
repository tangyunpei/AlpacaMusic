# macOS 与 Apple API 兼容性说明

核查日期：2026-09-30。本文依据当前源码、本机 Xcode SDK 声明及本次测试结果，区分编译兼容、已经运行验证的行为与尚未验证的范围。

## 系统与工具链

| 项目 | 当前要求或实测环境 |
| --- | --- |
| 最低运行系统 | macOS 26.0，见 `Package.swift` 的 deployment target |
| Swift 工具链要求 | Swift tools 6.4；项目使用 Swift 6 语言模式 |
| 本次开发工具 | Xcode 27.0，build 27A266a；Apple Swift 6.4 |
| 本次编译 SDK | macOS 27.0 SDK |
| 本次实际运行系统 | macOS 27.0.1，Apple Silicon |
| 编译门禁 | 可执行目标和测试目标均启用 `-warnings-as-errors` |

**尚未在 macOS 26 真机或虚拟机运行本应用。** 最低版本声明、26 deployment target 的成功编译和 `#available` 分支检查，不能代替 macOS 26 上的运行测试。发布前仍需在 26 上核验文件授权、播放、音频分析、Metal 和窗口交互。

### 打包时的 SDK 版本检查

本机 Swift 6.4 默认 SwiftBuild 路径存在一个已复现的链接版本记录差异：对象文件以 SDK 27 编译，普通 `swift build` 的最终可执行文件却记录 `sdk 26.0`。最小工程也能复现。当前 `scripts/build-app.sh` 因此显式传入 SDK 路径及 linker 的 `-platform_version macos 26.0 <实际SDK版本>`，并在打包前用 `vtool` 检查最低版本与 SDK；检查失败会停止打包。修正使用正常链接过程，没有事后修改 Mach-O，也没有切换到旧构建引擎。正式 `.app` 应使用此脚本生成；直接从 Package 运行的调试产物需另行检查版本记录。

## 当前弃用 API 审计

本次通过 SDK 27 头文件和 Swift interface 核对下列接口，并检查当前调用点。音频定向测试构建已在上述工具链下通过，未压制弃用警告，也没有使用 `-suppress-warnings`。

另将当前 `Package.swift`、`Sources`、`Tests` 复制到独立临时目录，仅在副本中将最低系统临时改为 macOS 27.0，再以原有 `-warnings-as-errors` 执行 `swift build`。**该 27 目标审计编译成功，无弃用诊断或其他警告。** 随后用 `xcrun vtool -show-build` 验证产物的 `LC_BUILD_VERSION`：`minos 27.0`、`sdk 27.0`，确认没有误用 26 目标进行这次审计。主工程的 `Package.swift` 已复核仍为 26.0；审计副本和产物不复制回主工程。

| 用途 | 当前实现 | 避免的旧接口及原因 |
| --- | --- | --- |
| 资产与元数据读取 | `try await asset.load(.isPlayable, .duration, .commonMetadata)`；元数据值使用 `item.load(.stringValue)` / `.dataValue` | Swift 的同步 `AVAsset.metadata`、`commonMetadata` 等属性从 macOS 13 弃用；不使用字符串 key 的 `loadValuesAsynchronously` |
| 支持的导入类型 | `AVURLAsset.audiovisualContentTypes`，按 `UTType.audio` 筛选 | 新属性从 macOS 26 可用；`audiovisualTypes` 在 SDK 27 标注 macOS 27 弃用 |
| 频谱变换 | `vDSP.DiscreteFourierTransform<Float>`，2048 点变换与 Hann 窗 | `vDSP.DFT` 的 Swift interface 已标注 deprecated，替代项为 `DiscreteFourierTransform` |
| 播放错误日志 | macOS 27 使用异步 `await item.errorLog`；26 从系统错误链提取安全的域与错误码 | 不调用 SDK 27 已弃用的同步 `errorLog()`；异步补充结果必须仍属于当前歌曲和失败事件 |
| 播放 | `AVPlayer` / `AVPlayerItem`，依据实际媒体状态与时间推进更新 UI | 没有调用 `AVAudioPlayerNode.play()`；该方法在 27 弃用，其新替代 `playAudio()` 仅 27 可用 |
| Apple Music | 原生 `MusicAuthorization`、`MusicSubscription`、`MusicCatalogSearchRequest`、`MusicCatalogResourceRequest`、`ApplicationMusicPlayer` | 不使用 macOS 不可用的 `SystemMusicPlayer`；不把 MusicKit 歌曲转换为 AVPlayer URL，也不读取受保护 PCM |
| 音频采样 | `MTAudioProcessingTap`，按运行系统选择下面的两条路径 | 没有调用 `AVAudioNode.installTap`；该方法在 27 弃用，其新替代 `installAudioTap` 仅 27 可用 |
| 网页登录 | `WKWebView`、非持久化 `WKWebsiteDataStore`、异步 Cookie Store 和导航代理 | 不读取其他浏览器数据；页面提交状态使用 Observation，登录按钮不等待无关资源全部完成 |
| 本机会话 | `SecItemCopyMatching` / `SecItemUpdate` / `SecItemAdd` / `SecItemDelete`；`LAContext.interactionNotAllowed` 禁止 LocalAuthentication 交互，但不保证阻止 file-based Keychain 的 ACL 授权提示；稳定签名用于保留应用身份 | 不使用 `SecKeychain`、已弃用的 `kSecUseAuthenticationUI`，不枚举其他凭证 |
| SwiftUI 富文本 | `Text` 插值组合 | 避免 macOS 26 已弃用的 `Text + Text` |

`AVPlayer.play()` 与 `AVAudioPlayerNode.play()` 是不同类型的方法：当前源码调用前者，不能因为方法名相同就将它判定为后者的弃用调用。

对应源码：`Sources/AlpacaMusic/MetadataImporter.swift`、`AudioAnalyzer.swift`、`PlayerController.swift`、`ContentView.swift`。本次检查的 SDK 文件包括 `AVAsset.h`、`AVAudioNode.h`、`AVAudioPlayerNode.h`、`AVAudioMix.h`、`MTAudioProcessingTap.h` 和 `Accelerate.swiftmodule/*.swiftinterface`。

Apple 的[异步媒体数据加载说明](https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously)介绍了 `load(...)` 的替代方式；类型和频谱接口可查阅 [audiovisualContentTypes](https://developer.apple.com/documentation/avfoundation/avurlasset/audiovisualcontenttypes) 与 [DiscreteFourierTransform](https://developer.apple.com/documentation/accelerate/vdsp/discretefouriertransform)。

这是一份当前接口审计，不是“以后永远不会弃用”的保证。Apple 可以在未来 SDK 修改可用性、行为或推荐接口；升级 Xcode 时需要重新审阅 SDK 声明、编译诊断和运行测试。特别是，以 26 为 deployment target 编译时没有警告，不能单独证明所有在 27 才弃用的接口均已排除；本次额外的 27 目标编译解决了这一诊断覆盖缺口，并保留源码与 SDK 声明的交叉检查。这个结果仅适用于本次被审计的源码和 SDK。

## 播放与真实音频分析

本地文件、音频链接及配置服务的播放地址交给 `AVPlayer`，本地文件在 `AVPlayerItem` 使用期间保持安全作用域授权；网络歌曲每次激活时重新解析可播放 URL。网络解析使用可取消任务及 generation 校验，晚到的旧结果不能复活已经清空或替换的播放项。

Apple Music 单独使用 `ApplicationMusicPlayer`，与 AVPlayer 共用应用队列，并在切换音源时停止前一引擎。MusicKit 的授权/订阅 API 从 macOS 12 可用，当前使用的原生播放器和目录请求可覆盖最低 macOS 26。其播放器状态的 Observation 支持从 26.4 才可用；本实现定时读取公开状态与时间，不依赖该较新的观察能力，不压制并发或弃用检查。Apple Music 不安装音频 tap、不驱动点云，不提供应用内音量滑块；显示原始封面，提示使用系统音量。

### macOS 27 路径

`AudioAnalyzer.audioMix(for:)` 在 `#available(macOS 27.0, *)` 分支使用不指定单条音轨的 `AVMutableAudioMixInputParameters()`。SDK 将其初始 track ID 定义为混合输出的特殊 ID：`AVAudioMixInputParametersTrackMixID`，值为 0。

该分支通过 `MTAudioProcessingTapCreateWithPreferredFormat` 请求 PCM 格式，读取播放器实际混合输出。实际格式仍以 tap 的 prepare 回调为准；代码不会假定系统必然返回请求的样本表示。

Apple 在 [WWDC 2026 HLS 更新，第 5 页](https://developer-rno.apple.com/streaming/Whats-new-HLS.pdf)说明了混合输出 tap 对 HLS 等 `AVPlayerItem` 的支持，并明确排除 FairPlay 保护音频。该平台能力依据官方资料；本次没有把实际 HTTP WAV 测试扩大表述为已经覆盖所有 HLS 或直播源。

### macOS 26 路径

26 分支异步读取普通资产音轨，以 `AVMutableAudioMixInputParameters(track:)` 和 `MTAudioProcessingTapCreate` 建立音轨 tap。后者在当前 SDK 没有弃用标记，因此这一兼容分支无需调用 27 已弃用的 `AVAudioNode.installTap` 或 `AVAudioPlayerNode.play()`。

26 分支跳过已知 `.m3u8` HLS 地址；无法取得可分析音轨、实际 PCM 未到达或格式不受当前分析器支持时，频谱能力保持不可用。播放本身继续由 AVPlayer 决定。**不承诺 macOS 26 的所有网络流都能提供 PCM 频谱。**

### 分析、播放与视觉状态的边界

- 音频回调只将 PCM 复制到预分配缓冲；竞争时跳过采样，避免阻塞音频线程。频谱变换由独立 utility 队列执行，不为每个音频 buffer 创建 Swift Task。
- 2048 点频谱用于 20–160 Hz 低频能量；采用约 50 ms / 300 ms 平滑、0.7 秒滚动均值、1.3 倍阈值、250 ms 节拍间隔和 350 ms 脉冲衰减。
- 当前 PCM 读取支持小端 Float32、Float64、Int16、Int32；不支持的 PCM 表示不会被误解析为可信频谱。
- `AudioLevels.available` 只在实际 PCM 足够且仍新鲜时为真。没有采样时不会用计时器、预设波形或歌曲长度伪造频谱。
- 暂停、静音和零音量使音频驱动的能量与节拍归零。视觉组件可以继续明确的静态或空闲展示，但这不代表取得了真实音频分析数据。
- 检测到受保护资产时不安装 tap；FairPlay、服务权限或不支持的分析格式不能通过替代或绕过授权获得 PCM。分析不可用不等于播放必然失败，二者分别反馈。
- 无穷或不确定时长按直播处理；不把它转换成虚假的有限时长，也不对其执行普通有限歌曲的进度跳转。

## 已运行的验证与未覆盖范围

`Tests/AlpacaMusicTests/PlayerTests.swift` 中的音频相关 16 项测试已通过，包括：

1. 通过安全书签读取真实本地 WAV，观察 AVPlayer 实际进入 playing、时间推进及非零 PCM 频谱，再验证跳转至 4 秒、暂停、静音和持久化恢复。
2. 使用本机 `NWListener` 提供支持 HTTP Range 的原创 WAV，验证网络播放、非零实际频谱，以及清空队列后旧任务不能重新开始播放。
3. 模拟服务在取消后仍返回成功，验证 generation 隔离；未配置音源必须失败，不把请求成功或调用 `play()` 本身当作已经播放。
4. 验证队列去重、移动、缺失文件跳过、随机历史、下一首优先和循环；验证音量滑块解除静音、拒绝非有限输入。
5. 将已知频率 PCM 输入分析器，核对频谱峰值；验证采样失效后归零，NaN 输入不会污染输出。
6. 检查三段原创 WAV 的 PCM 头、28 秒长度、真实非零且未削波的信号，以及文件和封面的生成。

真实播放测试使用独立临时目录和 `UserDefaults` suite，以 0.1% 音量短暂运行，等到非零真实频谱后继续静音与暂停测试。没有访问用户私人录音，也没有下载第三方版权音乐作为测试素材。

新增的 `AppleMusicTests.swift` 使用注入适配器完成 12 项测试，覆盖未配置构建零请求、拒绝后重试、停用时晚到结果、准备中暂停、慢速恢复、跨引擎切换、播放错误和真正曲终推进；断言无 PCM 与应用音量控制。此里程碑为 57 项通过；后续加入网页直连、会话与导入测试，当前总数见 [验证记录](verification.md)。全部新增源码同样通过 SDK 27 目标的弃用审计。

这些证据没有覆盖：macOS 26 实际运行、外网 HLS/直播稳定性、所有系统音频设备和解码格式、FairPlay 播放授权、Apple Music 开发者真实签名/自动 token/账户授权与订阅播放、QQ 真人账户的完整登录与播放、网易云各类会员或地区权限、直连账号的真实钥匙串恢复。默认连接已改为 Swift 直连，不再要求自托管服务。网页协议适配的自动测试使用独立测试响应；匿名公开请求仅证明相应公开端点可响应。用户自行操作后，曾在隔离检查实例观察到网易云歌单及实际播放状态，不能扩展为所有平台权限已验收。Apple Music 开通步骤见 [配置文档](apple-music-setup.md)。

可在项目根目录复核：

```sh
swift build
swift test --filter 'NativePlaybackTests|PlayerQueueTests|AudioAnalyzerTests|OriginalAudioTests'
```

测试成功属于功能与兼容性证据，不替代 macOS 26 实机验收、发布签名或公证。
