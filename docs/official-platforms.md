# 官方音乐平台接入

本轮实现面向 macOS 26 及以上，使用 macOS 27 SDK、SwiftUI 与 MusicKit。以下区分**已编码的能力**与**真实平台验收**，不以接口存在或测试替身通过代表账户已连接。

| 平台 | 当前代码范围 | 仍需条件与边界 |
| --- | --- | --- |
| Apple Music | 官方授权、订阅能力检查、歌曲目录搜索、个人曲库与歌单导入、通过 `ApplicationMusicPlayer` 播放，以及暂停、定位和队列切换 | 需完成开发者配置、用户授权和订阅检查；真实账户播放尚未验收 |
| Spotify | 系统浏览器 PKCE 登录、自动刷新、搜索、喜欢歌曲/歌单导入、官方设备播放/暂停/定位与状态同步 | 需 Client ID、回调登记和允许访问的账户；用户尚未配置，真实登录、导入与播放未验收 |
| 网易云、QQ 音乐 | App 内官网网页登录/扫码，Swift 直连网页接口，账户验证、搜索、歌单导入、播放地址解析；另保留高级自定义服务 | 网页接口适配并非官方开放平台 SDK；公开请求已验证，个人账户歌单与订阅播放仍需登录联调，见[账号连接说明](account-connections.md) |
| 其他平台 | 暂未实现 | 需分别核验官方能力、授权和使用条件；不承诺统一接口 |

## Apple Music：启用前提

拥有 Apple Developer 账户还不等于此应用已经可以使用 MusicKit。仍需：

1. 在开发者后台为应用建立 **Explicit App ID**，启用 **MusicKit App Service**，应用 Bundle ID 必须匹配。原生 MusicKit 使用自动 token 管理，不要求在播放器中填写密码或 `.p8` 私钥。[Apple 配置说明](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)
2. 使用对应开发者团队的真实身份签名，并按[配置步骤](apple-music-setup.md)启用本应用的构建配置。默认 ad-hoc 开发包不开放 Apple Music 连接。运行时会检查构建开关、团队签名与用途说明；这些本地检查**不能证明** Apple 后台已正确开通服务。
3. 应用须带有 `NSAppleMusicUsageDescription`，用户主动连接后通过系统授权。随后检查 `MusicSubscription.canPlayCatalogContent`；目录歌曲能否播放还取决于订阅、地区及曲目可用性。[MusicKit 官方说明](https://developer.apple.com/documentation/musickit)

搜索结果可加入 AlpacaMusic 自己的收藏、歌单和队列；当前不向 Apple Music 云端同步这些编辑。播放交给 MusicKit，使用原始封面和系统音量控制；本实现不提取 PCM、不提供 Apple Music 音频频谱或封面点云，也不下载歌曲。未配置或未启用时不会发起 MusicKit 连接；“停用”停止本应用使用该音源，系统授权仍由系统设置管理。

代码位于 `AppleMusicService.swift`，播放协调位于 `PlayerController.swift`。编译、测试替身与默认开发包检查只能验证程序行为；**App ID 服务、有效签名、真实授权、真实搜索和订阅歌曲播放仍需联调**。签名配置完成后应依次验证授权允许/拒绝、搜索、点播、暂停与定位、跨来源切换、订阅不可用和停用行为；本地媒体测试不能替代这些检查。

## Spotify：配置与播放

更新于 2026-10-03，采用官方公开 Web API；没有运行 Spotify 逆向代码，也不读取官方客户端的 Cookie。

1. 以 Spotify 账号打开 [Developer Dashboard](https://developer.spotify.com/dashboard)，创建应用并选择 Web API。
2. 在应用设置的 Redirect URIs 登记 **`http://127.0.0.1:43821/callback`** 并保存。必须使用此处完整地址，不能改成 localhost。[回调规则](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri)
3. 在 AlpacaMusic → 音源 → Spotify → 接入设置粘贴 Client ID，然后点击登录。无需 Client Secret；系统浏览器登录并确认权限后返回 App。
4. 开发模式下，应用所有者需要 Premium，新应用最多允许 5 位测试用户；其他使用者需列入 Dashboard 用户列表。2026 年 7 月每开发者 Client ID 上限变为 25，配额仍在开发者账户内共享。[开发模式迁移](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)、[7 月变更](https://developer.spotify.com/documentation/web-api/references/changes/july-2026)
5. 导入歌单或喜欢的歌曲。开发模式只允许读取本人创建或参与协作的歌单内容；可列出歌单元数据不代表能读取其中曲目。导入保存在本地，不修改 Spotify 云端收藏。
6. 打开 Spotify 官方 App 或网页播放器并播放一次，在 AlpacaMusic 的“播放设备”中刷新/选择设备，再选歌。播放需要 Premium；声音由官方设备输出，AlpacaMusic 不提取音频直链或 PCM，不提供 Spotify 实时频谱。音量在官方设备上调节。[播放接口](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback)

### 接口迁移范围

- 授权使用 PKCE S256 和随机 state；临时回调监听器仅绑定 IPv4 loopback，有大小/时间上限，退出登录窗口后关闭。
- 令牌保存在独立的本机钥匙串项目中，按 Client ID 区分；启动仅在曾连接时恢复。取消或换号后的旧请求不能发布新账户状态。
- 搜索按每页最多 10 首分页；歌单读取使用 `/playlists/{id}/items` 及新 `item` 字段，同时兼容返回体中的旧 `track` 字段，不调用已弃用的歌单 tracks 路径。
- `/me` 不依赖被移除的 country/email/product 等字段；优先采用 2026 年 5 月新增的稳定 `account_id`。[2 月迁移](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)、[5 月变更](https://developer.spotify.com/documentation/web-api/references/changes/may-2026)
- 对 401 至多刷新后重试一次；429 尊重 Retry-After，区分账户共享配额 `QUOTA_EXCEEDED`。网络超时不会自动重发播放命令。
- API 与令牌请求不携带浏览器 Cookie，拒绝重定向和越界分页地址；失败信息不输出令牌或完整响应。
- 播放每两秒检查官方设备状态；外部切歌/切设备时释放控制，避免暂停或跳转用户正在其他设备播放的歌曲。未确认曲目状态前不显示已成功播放。

### 验证范围与公开分发

代码和模拟接口测试不等于 Spotify 实际批准此产品或账号已连接。本次用户没有 Client ID，真实浏览器授权、个人歌单和 Premium 播放需配置后联调。端口 43821 被占用时应明确失败，不能静默改用未登记的回调。

公开分发前仍需核对适用于聚合播放器、视觉呈现和远程播放的 [Developer Policy](https://developer.spotify.com/policy)、[Terms](https://developer.spotify.com/terms) 与 [设计规范](https://developer.spotify.com/documentation/design#using-our-content)，以及应用实际获批的配额和产品范围。此实现不代表平台审批已经完成。
