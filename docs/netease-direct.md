# 网易云直接连接

`NeteaseDirectProvider` 使用纯 Swift 请求网易云网页端，不需要另行部署 API 服务。它只接受本应用扫码或官网登录窗口取得的会话，要求有效 `MUSIC_U`；不读取 Safari、Chrome 或网易云客户端的现有账号数据。扫码登录窗口通过独立 `NeteaseQRAuthentication` 承载官网当前 `CtWebLogin` 组件，详见[扫码登录](netease-qr-login.md)。应用不自行实现密码或短信登录；若官网要求安全验证，由用户在可见官方组件中完成。

## 请求范围

以下曲库与播放接口请求固定发送至 `https://music.163.com`，采用网页 `weapi` 请求封装（双层 AES-CBC 与 RSA 公钥封装）。这只是协议编码，不会赋予账号权限；请求正文与共享 `NativeMusicHTTP` 请求头使用同一 Cookie 匹配和排序规则，按域名、路径及有效期筛选，并将较长路径排在前面。正文 `csrf_token` 与请求头首个同名 `__csrf` 保持一致；不存在适用令牌时保留空值，不伪造 Cookie。禁止携带会话跨域跳转。

| 功能 | 网页接口 |
| --- | --- |
| 确认登录身份 | `/weapi/w/nuser/account/get` |
| 搜索歌曲 | `/weapi/cloudsearch/pc` |
| 用户歌单，逐页读取 | `/weapi/user/playlist` |
| 完整歌单曲目 ID | `/weapi/v6/playlist/detail` |
| 按 ID 分批读取歌曲资料 | `/weapi/v3/song/detail` |
| 当前账户可用的标准音质地址 | `/weapi/song/enhance/player/url/v1` |

歌单先读取完整 `trackIds`，再每批 200 首获取资料，最终恢复原歌单顺序；缺少资料的 ID 保留为不可用曲目。返回曲目 ID 不完整、分页停滞、请求中断或超过 10000 首时明确报错，不把部分结果当成完整导入。这里只读取账号、搜索及歌单，没有修改网易云收藏或云端歌单的接口。

播放仅接受网易云返回的 `music.126.net` / `music.163.com` 官方域名地址。按官网 HTTPS 页面播放器的行为，将官方 HTTP 音频地址升级为 HTTPS，移除原 HTTP 80 端口，保留主机、编码后的路径及查询参数；最终仅允许无显式端口或 443，拒绝其他端口。缺少权限、地址为空、仅有试听或触发平台验证时停止并提示；没有解灰、第三方替代音源、IP 伪装、自动完成平台验证或破解下载功能。登录状态、订阅、地区与版权仍由平台决定。

## 播放失败提示

播放请求保留接口码、单曲业务码及操作阶段，区分未返回所选歌曲、空地址、试听片段、无效地址、响应变化与连接问题。官网播放器使用 `encodeType=aac`，且没有要求单曲结果一定带 `code`；因此顶层成功、曲目匹配且返回完整官方地址时，单曲 `code` 缺失不再被误判为无权限。明确非成功的单曲码仍拒绝播放。

HTTP 层分别解释 401（需要有效登录）、403（访问被拒绝，原因未确认）、404（接口或资源未找到）、429（请求频繁）及 5xx（服务异常），保留 HTTP 状态且不回显正文。HTTP 404、顶层业务 404 和单曲业务 404 分开显示，不能单凭 404 推断歌曲下架、会员不足或账号失效。`freeTrialInfo` 缺失或 `null` 保持原有处理；包含有效起止时间的对象明确提示试听；布尔值、数字、字符串、不完整对象等无法识别形态继续拒播，但提示“无法确认完整播放”，不断言已确定为试听。

仅当单曲业务失败或地址为空时，额外查询一次 `/weapi/v3/song/detail` 权限资料（请求超时 5 秒），不会尝试其他播放来源。解释遵循官网的 `st`、`pl`、`fee`、`payed`、`flag` 组合条件：收费分类本身不能证明当前账户无权播放；负 `st` 只能说明平台标记不可用，不能单独认定下架或地区限制。详情不足或补查失败时明确说明原因未确认，并保留原播放业务码。平台只给试听时停止，不宣称购买某项服务一定能解决。

界面错误仅使用应用自己的说明和数值字段，不回显平台原始正文、Cookie、签名播放地址或响应中的任意提示文本；取消请求仍作为取消处理。

## 协议依据与验证边界

匿名读取当前网易云官网及其公开 [core 脚本](https://s3.music.126.net/web/s/core_c7686f506f6f2607bb7f6cea1951f039.js)、[页面脚本](https://s3.music.126.net/web/s/pt_frame_index_2b8192306764f32086606cd3d6d62d64.js)，确认网页的加密层及身份、歌单、曲目和播放路径。请求参数另外对照社区上游的[身份接口](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/main/module/login_status.js)、[搜索](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/main/module/cloudsearch.js)、[歌单分页](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/main/module/user_playlist.js)、[完整曲目读取](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/main/module/playlist_track_all.js)与[协议编码](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/main/util/crypto.js)。未引入或运行该上游的软件、解锁或代理逻辑。

2026-10-01 重新匿名核验：用户指定的 [Binaryify/NeteaseCloudMusicApi](https://github.com/Binaryify/NeteaseCloudMusicApi) 已于 2024-04-16 归档，当前主分支仅保留停止维护说明，没有可当作最新实现的接口源码。历史参考使用作者发布的 [NeteaseCloudMusicApi 4.15.0 元数据](https://registry.npmjs.org/NeteaseCloudMusicApi/4.15.0)（gitHead `35e1807c4c9353756bc5d57a1958f47d1e8fbf5f`）及其[播放模块](https://cdn.jsdelivr.net/npm/NeteaseCloudMusicApi@4.15.0/module/song_url_v1.js)、[请求编码](https://cdn.jsdelivr.net/npm/NeteaseCloudMusicApi@4.15.0/util/request.js)。历史模块使用移动端 `eapi`、`flac` 及相应客户端参数；当前官网播放器则使用 `weapi`、`aac`。本应用保留已有 `standard+aac`，没有仅因官网默认 `exhigh` 就提升音质，也没有将历史移动端参数拼入网页请求。此次修正的是可验证的请求一致性、URL 处理及错误解释，不保证任何具体歌曲或账号因此获得播放权限。

2026-10-04 登录补充：官网页面保留的旧二维码代码已经不是实际登录入口，现由[官方 CtWebLogin 0.3.7 组件](https://st.music.163.com/g/ct-web-login/ctWebLogin.main.0.3.7.1cebd5b7.js)接管。组件收到扫码状态 8821 时停止轮询并显示安全验证码，用户完成后继续验证；应用窗口已按这一方式调整。本轮真实扫码确认与安全验证码后的完整连接仍待联调，详见[扫码登录验证边界](netease-qr-login.md#验证边界)。

这属于网页协议适配，并非网易云公开承诺稳定的官方 SDK。曾发送两次不带 Cookie 的只读请求：身份接口返回 `200` 且无登录用户，搜索接口返回 `200` 与歌曲结果，验证了网页协议可响应。本次再次匿名读取上述官网 core 脚本，核对播放器请求及权限判断；没有读取用户真实会话，也没有针对失败歌曲发出带登录状态的网络请求。

`NeteaseDirectTests` 与 `NativeMusicHTTPTests` 使用注入响应覆盖加密向量、登录、分页、曲目完整性、Cookie 路径优先级、无适用 CSRF、HTTPS 升级保留签名参数、异常端口拒绝，以及缺少单曲码、空地址、HTTP / 业务失败、试听与未知试听标记、权限组合、补查失败、取消、超时和敏感信息不回显。测试能证明这些响应的处理方式，不能证明具体账号已获得某首歌的播放权限；用户报告的实际失败仍需由新提示中的阶段与业务码进一步定位。
