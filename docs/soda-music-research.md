# 汽水音乐接入研究

研究日期：2026-10-03（America/Vancouver）。接口实测使用匿名临时会话，没有读取用户既有浏览器、汽水音乐或抖音凭据。

## 最新同机对照与详细调研

用户许可后，打开通过字节跳动签名验证的官方 Mac 3.7.0 / 1856；用户自行扫码确认，官方登录弹层消失并显示账号入口。对照后正常退出，没有导出其 Cookie 或账号凭据。AlpacaMusic 的私人曲库仍未接通；现有 2156 应继续核对消费者完整初始化和运行环境差异，不能归因于账号不可用。官方 UI 提示 3.8.0 更新，所以 3.7.0 是本轮固定样本。

最新[第三方接入调研](soda-thirdparty-integration-2026-10-03.md)汇总正式 OpenAPI、网页登录边界、六个第三方实现的固定源码版本、同机对照和后续验证项。下面保留既往协议和测试记录；其中“官方客户端尚未对照”属于当时进度，以本节为准。

## 官方入口与实现边界

- [汽水音乐官网](https://qishui.douyin.com/) 与 [www.qishui.com](https://www.qishui.com/) 当前提供产品介绍及官方客户端下载。`www.qishui.com/track/<id>` 实测也返回这个首页，不能作为已连接曲库或登录成功的证据。
- [官方歌曲分享 H5](https://music.douyin.com/qishui/share/track?track_id=7079108541549643812) 返回歌曲公开信息及试听页面。其播放器、SDK 与版权仍属于平台；AlpacaMusic 不复制或打包官方网页资产。
- 通用账号 SDK 的 `qrcode_index_url` 指向 `bff-pc.qishui.com/ucenter_web/app/sdk-next`，普通浏览器及本次用户手机扫码均出现 404。当前官方 PC 3.7.0 另行生成汽水音乐 App 的扫码 H5，见下文；不能继续把通用 SDK 的条码当成当前 PC 登录入口，也不能把它伪装成可嵌入的网页登录页。
- 已找到抖音开放平台正式汽水接口：[首页推荐](https://developer.open-douyin.com/docs/resource/zh-CN/dop/develop/openapi/qishui-music/feed-song-tab)、[相关歌曲推荐](https://developer.open-douyin.com/docs/resource/zh-CN/dop/develop/openapi/qishui-music/related-media)，使用应用级 client_token 与 luna.openapi.platform.play_core。尚未核验私人歌单导入、会员授权或原生 macOS 播放 SDK 的正式能力；不可泛称没有官方 API。详细核验见[第三方接入调研](soda-thirdparty-integration-2026-10-03.md)。
- [用户协议](https://luna-web.douyin.com/terms)、[隐私政策](https://luna-web.douyin.com/privacy) 仅由界面提供链接；应用不代替用户接受协议，也不替用户完成手机确认。

## 公开接口实测

以下请求在当前网络环境返回有效 JSON。成功响应可能没有 `status_code`，只有 `status_info`；不能把缺失状态码当失败，也不能把 HTTP 200 的空响应当成功。

| 能力 | 官方地址与参数 | 当前验证 |
| --- | --- | --- |
| 歌曲搜索 | GET `https://api.qishui.com/luna/search/track?q=周杰伦&cursor=0&count=20&aid=386088` | 匿名、普通浏览器 User-Agent 可返回 `result_groups[].data[].entity.track`；未使用抓取的设备 ID 或签名 |
| 同源搜索替代域名 | GET `https://beta-luna.douyin.com/luna/search/track`，同参数 | 同样返回结果 |
| 曲目详情、公开歌词及试听 | GET `https://beta-luna.douyin.com/luna/h5/seo_track?track_id=7079108541549643812&device_platform=web` | 返回 `seo_track.track`、`lyric`、`track_player`；实测《小半》 |
| 歌单详情 | POST `https://beta-luna.douyin.com/luna/playlist/detail`，JSON `{playlist_id:"7096700219496368135",count:20}` | 返回歌单及 6 个 `media_resources`；需按 `has_more` / `next_cursor` 读取后续页，并对重复游标设界限 |
| 推荐歌单 | POST `https://beta-luna.douyin.com/luna/discover/mix`，JSON `{count:10}` | 返回 10 个 `inner_block`，其中资源位于 `resources[].entity.playlist` |
| 发现页 | POST `https://beta-luna.douyin.com/luna/discover`，JSON `{}` | 返回 `blocks` |
| 账号验证 | GET `https://api.qishui.com/luna/pc/me?aid=386088` | 无登录态时明确返回 `status_code=1000016`，登录状态已失效 |
| PC 搜索及详情 | `/luna/pc/search/track`、`/luna/pc/track_v2` | 本次普通匿名请求 HTTP 200，但响应体为空；未验证可用，不能据此宣称已接入整曲播放 |

曲目数据：`id` 是长整数字符串，应保留字符串精度；`duration` 是毫秒；歌手为 `artists[]`；封面 `album.url_cover` 可能是 `{urls:["https://p3-luna.douyinpic.com/img/",...],uri:"tos-cn-v-2774c002/..."}`，使用可信基础 URL 与 URI 组合。歌单中的曲目可能嵌在 `entity.track_wrapper.track`。

歌词原式为 `[句开始毫秒,句持续毫秒]<词相对偏移毫秒,词持续毫秒,标志>文本`。例如本次匿名响应第一句含 `[60,1470]<0,350,0>不...`，原始逐字时间应保留供动态字幕使用；不应先降级为整句 LRC 后再猜词时间。

## 普通扫码登录

当前生产流程已改为独立非持久化 WebKit 会话，见本文最后一节；本节的公共参数、条码目标与状态语义仍使用，Cookie 与回调处理以最后一节为准。原生 HTTP 的三跳回调是旧实现，已移除，不能当作新版能力。

已实测：匿名 HTTP 创建二维码及轮询，服务端返回 `new`、`error_code=0`。加入当前 PC 的公开参数、移除参考项目中的固定 `iid` 后，创建与 `new` 轮询仍正常。尚不能用这些结果证明用户手机确认后的登录回调或曲库已验证。

创建：GET `https://api.qishui.com/passport/web/get_qrcode/`。

- 固定公开参数：`passport_jssdk_version=2.4.13`、`passport_jssdk_type=normal`、`is_from_ttaccountsdk=1`、`aid=386088`。
- 当前 PC 公开参数：`is_from_iesaccountsaas=1`、`device_platform=PC`、`version_code=3.7.0`。不采用官方客户端的真实设备标识、参考项目固定的设备/安装 ID 或抓取的签名。
- 其他参数：`next=https://api.qishui.com`、`need_logo=false`、`need_short_url=false`、`is_new_login=1`。
- 返回 `data.token`、`data.qrcode`、`data.qrcode_index_url`、`data.expire_time`、`data.copywriting`。`expire_time` 本次为 Unix 秒时间戳；通用 SDK 的 `copywriting` 虽写「抖音 APP」，当前 PC 3.7.0 使用自己的条码与扫码指引，应以当前 PC 实现为准。
- 本次用本地 Vision 解码官方 `qrcode` PNG，条码内容与 `qrcode_index_url` 完全一致，直接切换成官方 PNG 不能修复 404。
- 核对 `qrcode_index_url` 是受信任的官方 HTTPS 地址，且其唯一 `token` 与 `data.token` 一致。依照当前官方 PC 流程，从该 token 生成 `https://bff-pc.qishui.com/light/invoke/scan_login`，参数为 `token`、`os=Mac`、`computer_name=AlpacaMusic`；不读取或上传用户真实电脑名称，不复制官方 JS。
- 当前官方指引：在「汽水音乐 App」打开「搜索」，点击搜索框右侧「扫一扫」。可先用自己的抖音账号登录汽水音乐 App，但抖音 App 的普通扫码入口不能代替这个汽水扫一扫。
- `token` 不记录到日志或错误消息。新的 H5 对普通网页请求返回重定向，落到 `sodamusic-desktop/scan_error.html`；包含 Safari、抖音与 Luna 示例 User-Agent 的匿名请求都未验证真人确认闭环。HTTP 200 错误页不能当成手机登录成功，仍需用户在正确 App 入口自行扫码检查。

轮询：POST `https://api.qishui.com/passport/web/check_qrconnect/`。

- Query：上述 SDK、`aid` 和当前 PC 公开参数，不传参考项目中固定的 `iid` 或 `device_id`。
- 表单：`need_logo=false`、`need_short_url=false`、`is_frontier=true`、本次 `token`、`is_new_login=1`、`next=https://api.qishui.com`。
- 保留本次创建返回的 `passport_csrf_token` 等临时 Cookie，仅发送给匹配的官方主机/路径。
- 最小轮询间隔 2.5 秒，截止时间不超过 180 秒；错误 7 或 HTTP 429 最多连续重试 3 次，每次等待 5 秒。持续限流应给出重试入口，不能无限显示「正在连接」。
- `scanned` 仅表示已扫码；只有服务端确认本次二维码且取得真实会话 Cookie 后，才提交账号验证。`sessionid` 等响应体字符串不能被伪造为 Cookie。
- 回调只接受 HTTPS 精确主机 `api.qishui.com` / `bff-pc.qishui.com`，最多 3 跳；跨主机跳转不转发 Cookie。不采用 `--disable-web-security`，不移植浏览器签名组件，不读取用户浏览器资料。
- 错误 2046 表示二次身份验证。本轮原生扫码没有验证该闭环，应停止并明确提示，不能将其当登录成功。
- 取消会清除临时凭据并使本次请求失效；迟到的网络响应不能调用账号连接，迟到的验证结果不能关闭弹窗或显示连接成功。

## 试听与整曲

`track_player.video_model` 是 JSON 字符串，`video_list[]` 含 `main_url` / `backup_url` / `video_meta`。公开 H5 的这个值不能默认解释成整曲。

《小半》实测：完整曲目 `duration=297240ms`；公开试听 `preview.start=143808ms`、`preview.duration=30047ms`、`video_duration=30.047s`。官方 URL 为 HTTPS `v3-luna.douyinvod.com`；仅请求 4096 字节 Range 的探针返回 HTTP 206、`audio/mp4`、`ftyp M4A` 与 `mp4a`，该头部未发现 `enca` / `sinf` / `pssh` / `senc`。这支持当前公开试听是普通 M4A 的判断，但不能证明其他曲目或所有档位都未加密。

响应中即使出现 `gear_des_key` 也不应仅凭此就把普通试听判定为加密；同样不能忽略资源的加密标记。遇到受保护的 CENC / `spade_a` / 需要客户端签名的取流路径，本轮不实现解密、签名伪造或权限绕过，应保留具体不可播原因。

试听播放必须明确标注身份，采用试听真实时长。歌词时间应从完整歌曲时间减去试听开始时间，并处理跨越试听起点的句/词；不能让 30 秒音源显示成 4 分钟，也不能把试听起点误当全曲 0 秒。

登录、个人曲库、会员整曲的可用性必须在用户自行扫码确认后继续检查，不能从匿名推荐或歌词可访问推断账号权限。

## 交叉核对资料

仅研究协议和数据格式，没有把以下项目的实现或官方安全资产直接引入应用。

- [guowenye/qishui-api](https://github.com/guowenye/qishui-api)（MIT）：核对公开端点、QRCode / profile / playlist 参数与字段。
- [libresoda CLIENT-API](https://github.com/sodahub-org/libresoda/blob/main/docs/CLIENT-API.md) 及 [扫码现状](https://github.com/sodahub-org/libresoda/blob/main/docs/QR-LOGIN.md)（AGPL-3.0-or-later；研究快照 `f02497e4c58502917812e2552a43c9e714226eb3`）：2026-09-15 社区真机记录显示部分扫码后请求会错误 7 限流，会话可能只留在浏览器上下文。其「原样扫描通用 SDK URL」结论已被本次用户 404 与当前 PC 3.7.0 的官方流程取代；其签名器及官方安全资产不适合作为本轮原生接入依赖。
- [guohuiyuan/music-lib](https://github.com/guohuiyuan/music-lib/tree/main/soda)（研究快照 `28e1080ba4160a26af32f35c5b597f63e35fdba8`）：核对 App 搜索、歌词、分页、公开字段。未复制其中固定的手机设备信息或解密实现。
- [官网动态 PC 下载配置](https://is.snssdk.com/service/settings/v3/?caller_name=luna_home_page&device_id=0) 当前指向 [官方 PC 3.7.0 临时研究包](https://lf-luna-release.qishui.com/obj/luna-release/3.7.0/452316191/SodaMusic-v3.7.0-official-darwin_arm64.tgz)。仅在临时目录读取 `main.asar/assets/renderer-D6Qqqsux.js`：`getHandleScanCodeH5Img` 使用上述 `/light/invoke/scan_login` 目标；`getScanCodeDesc` 显示汽水音乐 App 搜索框「扫一扫」；公开配置为 `device_platform=PC`、`version_code=3.7.0`。官方资产没有加入 AlpacaMusic。

验证状态：公开 API / 匿名二维码创建 / 首次 `new` 轮询已实测；用户手机确认、账号恢复、私人歌单与账号授权整曲尚待真实账号验证。原生登录状态、限流、取消和隔离的注入测试见 `SodaLoginTests.swift`；最终检查结果见下方。


## 本轮实现与已完成验证

AlpacaMusic 新增独立汽水音乐来源，不增加自定义服务配置，也不要求部署服务器。公开搜索可在音源页关闭。分享歌曲/歌单导入保存身份、封面与可核对的片段范围；临时音频 URL 不写入曲库或恢复队列，每次播放会重新获取并核对身份和范围。

已执行官方接口联调：搜索、公开分享歌曲、完整公开歌单、普通音频地址刷新与逐字歌词裁切均通过。公开分享曲目已保存的片段会显示「试听」；只有播放范围变化时才重新加载对应歌词，保留句中空档与精确词结束时间。正式包保留现有开发者签名、MusicKit 配置、macOS 26 最低版本及 macOS SDK 27。

2026-10-03 的最终完整回归检查通过 501 个测试、46 个套件；macOS SDK 27 API 审计通过。登录测试验证创建、轮询、会话与账号确认顺序、限流、过期、取消和 Cookie 隔离，但注入测试不等于用户已在手机完成登录。私人曲库与账号授权整曲仍需要真实账号联调；扫码入口不能承诺提供会员整曲。


原生界面实测：官方《小半》分享链接解析为陈粒歌曲，导入前显示 30 秒试听与原曲 2:23–2:53 范围；保存后来源与时长保持试听身份。首次 AVPlayer 加载曾返回 `NSURLErrorDomain -1008 / NSOSStatusErrorDomain -16845`；重新获取地址后实际播放、实时频谱及逐字歌词正常。另有真实 PlayerController 光谱/PCM 测试与同 URL AVURLAsset 探针证据；AAC 实测时长约 29.99855 秒，与官方 30.047 秒相差约 48 毫秒。不同 UA 与 Referer 请求均可读取，尚无证据认定首次失败原因，也未增加未公开的 AVFoundation header key。

用户本次扫码曾显示 404；已核对官方返回 PNG 的条码与 `qrcode_index_url` 完全一致，换为官方图片不能修复此跳转。随后核对当前官方 PC 3.7.0 临时包，确认它改为自己的 `/light/invoke/scan_login` H5 以及汽水音乐 App「扫一扫」，已据此更新原生条码生成和指引，并增加官方 token 缺失/不一致/重复值拒绝测试。用户随后使用汽水音乐 App 的正确入口扫码并确认，桌面轮询返回错误 2156。当前尚未取得经账号接口确认的有效登录会话；不能称账号接入已完成。


## 手机确认后错误 2156 的核对与协议修正

2026-10-03，用户已用汽水音乐 App 扫码并在手机确认，但 `check_qrconnect` 返回 2156。该次只保存了界面错误码，没有保存完整平台说明或状态字段；失败后本次临时 token 已清除。不能在不重新扫码的情况下回溯这个响应，更不能凭 2156 的数字推断账号权限、风控、签名、限流或过期。当前官方 PC 3.7.0 资产未找到 2156 的专门映射；其扫码组件对未单独处理的业务错误显示平台 `description` 并停止轮询。

继续只读核对同一 [官方 PC 3.7.0 包](https://lf-luna-release.qishui.com/obj/luna-release/3.7.0/452316191/SodaMusic-v3.7.0-official-darwin_arm64.tgz) 的 `renderer-D6Qqqsux.js`：实际扫码实例是 `qne` 的 `WebInterfaceSdk=Mne`，继承链 `Mne → ZJ → K0`；`K0` 的 `sG` 在当前无 `fetch` 配置时使用 `Gq`，注册 `Fq`、`$q` 和 `S7`。这明确定位到实际使用的 SDK，并不是看到另外一个 lite SDK 的字符串就切换实现。

- `Fq` 将自身 `passport_csrf_token`、其次 `passport_csrf_token_default` 镜像到 `x-tt-passport-csrf-token` 请求头，且设置 `Accept: application/json, text/javascript`。原生实现此前只发送匹配的 Cookie，遗漏这个头；现在从本次私有 cookie jar 补齐，只作用于 `api.qishui.com/passport/` 请求，跨主机回调不携带这个头。
- `Mne` 确实包含 `Y0` 与 `Dne` 插件。`Y0` 的公开字段是 `passport_jssdk_version=2.4.13`、`p_js_v=2.4.13`、`p_js_t=pro`、`p_ver=1.0.29`。默认 `qG` 插件先写 `passport_jssdk_type=normal` 与 `account_sdk_source=web`，后续 `Y0` 覆盖版本；`$q` 的 lite 值只是默认值，已有 normal 被保留。因此原生保留 normal、加入已核对的公开字段与 `language=zh`，不猜测切换 lite。
- 官方扫码组件在创建前生成 `UUID + .login`，`Dne` 用 `x-tt-passport-verify-portrait` 发送该流程关联标识。原生现在在每次获取二维码前生成自己的随机 UUID，创建与轮询保持一致，重新获取时更换；它不来自官方设备资料，不是账号密钥。跨主机回调不发送该头。
- `S7` 的追踪标识是本次 SDK 实例生成的 8 位十六进制值，同时进入 `biz_trace_id` query 与 `x-tt-passport-trace-id` header。原生同样为每次获取生成自己的随机 8 位值，创建/轮询一致，刷新更换；回调不发送该头。它仅用于流程关联，不借用官方设备或账号身份。
- 官方的真实 `device_id / install_id / did / iid` 来自 native global config；`request_host`、`p_bd`、`p_zt` 与浏览器/安全组件运行时有关。本轮不复制、伪造或猜测这些值，不实现官方签名组件。上述修正不能称全部官方请求已经对齐，也不能证明这些差异就是 2156 的原因。

失败诊断现在区分「获取二维码」与「扫码确认」，检查 root 和 `data` 两层的业务错误码；外层失败不能被内层 `error_code=0` 或确认状态覆盖；有 `data` 包装且 `message=error` 等失败标记时，即使没有数字错误码也明确停止，不制造错误 0 或 -1。平台说明只保留有限长度的人类可读文本，去除二维码 token、当前 Cookie 值、两层响应中的敏感字符串、带凭据链接、邮箱、手机号及长凭据片段；包装字段 `message=success` 不显示为失败原因。平台未提供有效说明时直接写「平台未提供具体原因」，不编造错误含义。2156 停止轮询并允许关闭/重新获取，不自动无限重试。

Cookie 接收也修复了两处独立错误：合法 `Set-Cookie` 可为后续 `/luna` 等路径设置会话，不能因为当前响应位于 `/passport/` 就丢掉；过期或 `Max-Age=0` 的删除指令应先删除相同 name/domain/path 的旧值，再丢弃删除值。发送仍严格检查主机、路径、有效期和 HTTPS。无私人数据的 Foundation 真实响应探针显示，URLSession 合并多条 `Set-Cookie` 后，系统解析器仍能保留含逗号的 Expires、后续路径和过期删除，因而没有添加脆弱的自制逗号拆分器。SwiftUI 捕获异常时保留已过期状态，不再把 `.expired` 改成普通 `.failed`。

新增注入测试覆盖 CSRF 主值/备选值/路径与主机作用域、portrait 与 trace 的本次一致性和刷新、公开元数据、2156 说明脱敏与有界长度、外层错误及巨数不能被内层成功掩盖、后续路径会话、过期删除、跨主机头隔离与无数字码的失败包装。Foundation 属性探针确认，`Max-Age=0` 被系统转换为真实墙钟时间的 `Expires`，其 `maximumAge` 属性未保留；删除测试据此使用真实时间与动态 QR 截止时间，不拿 1970 年假时钟误判系统解析的删除指令。另提供显式 `ALPACA_LIVE_SODA_QR=1` 的匿名创建与一次 `new` 轮询测试，结束即取消，不展示或记录 QR URL、token 和 Cookie。此次补丁的 34 个登录与集成测试、2 个套件已通过。显式开启匿名实测后，创建与一次 `new` 轮询也实际通过（1 个测试、1 个套件，约 1.7 秒）。正式构建通过原开发者签名验证，保留 MusicKit、bundle ID 与 macOS 26 最低版本。此次协议补丁安装后，用户再次在汽水音乐 App 确认，正式界面仍返回 2156，平台原文为「系统繁忙，请重启应用或刷新页面后重试」。真实确认没有通过，个人曲库尚未连接；历史 501 个测试结果、34 项注入测试及匿名 `new` 均不能作为 2156 已修复的证据。用户尚未尝试官方电脑版，当前没有同机官方客户端的对照结果，不要求用户为此次研究安装或重复扫码。


## 第二次真实确认失败与 WebKit 运行时验证

上述协议补丁安装后，用户再次在汽水音乐 App 扫码并确认，正式界面仍显示 2156，平台说明为「系统繁忙，请重启应用或刷新页面后重试」。当前未核实该码的官方业务定义；此文案不能证明临时故障、账号问题、限流或签名缺失。用户尚未试官方电脑版，当前没有同机官方客户端的对照结果。

继续检查官方 PC 3.7.0 的 `main.html`，它在应用脚本前加载官方远程 SDK Glue 1.0.0.36，并以 aid 386088、pageId 24554 初始化；BDMS 的路径范围为 `/passport`。这条浏览器校验链独立于账号接口中的 `ztsdk:false`。本轮公开 TCC 配置未包含 aid 386088，不能据此泛称扫码必须 ticket-guard 签名。真实 device/install 标识仍来自原生 global_config，公开资产未给出可核对的设备注册协议；不会借用官方客户端标识或编造这些字段。

已执行独立、匿名的 macOS WebKit 实测。新的非持久化会话真实导航到 `https://api.qishui.com/`，实际响应是 HTTP 404 的 HTML 页面；它不是官方托管登录组件，仅用于验证该真实 origin 内的运行时可行性。没有合成 origin、关闭 CORS/CSP/TLS、修改 UA 或读取别的应用 Cookie。随后正常加载上述官方远程 SDK。实测 export 与 init 成功，fetch/XHR hook 均改变；实际 passport 请求中出现签名参数（只记录是否存在，不记录参数值）。创建二维码 HTTP 200、业务码 0，间隔约 2.6 秒后的唯一轮询 HTTP 200、业务码 0、状态 `new`，没有 CSP 违规。没有展示二维码、读取真实账号或要求用户扫码，结束后退出独立测试应用并释放临时会话。

此实测证明浏览器校验运行时与匿名创建/轮询在当前环境可用，不能证明 2156 的根因或手机确认后的账号连接已恢复。新版默认登录使用独立非持久化 WebKit 会话完成同源请求，从自身 `WKHTTPCookieStore` 获取真实 Cookie；不会伪造 JS 不可读的 `Set-Cookie`、手工设置浏览器 Cookie/Origin/UA，或移植官方签名实现。跨 origin 回调需要另行验证，不能沿用原生手工跳转规则绕过 CORS；没有有效会话时明确停止。成功仍以真实账号资料验证为准。


新版实现使用 macOS 26 已支持的 `WKWebView`，每次创建先建立自己的 `.nonPersistent()` 数据存储，并在登录 sheet 的原生视图生命周期挂载。界面继续显示二维码与状态，API 根的 404 文档不会成为可见页面。远程 SDK 必须正常加载，且 fetch 与 XHR open/send 实际 hook 均改变，才能发起请求；不能只有一个导出变量就宣称已就绪。SDK 或请求失败会给出具体阶段的固定说明，不退回未验证的原生请求再次要求扫码。

同源请求只允许 `api.qishui.com` 上的二维码创建与状态检查两条固定路径，保留浏览器真实 origin 与 UA，不发送自制 Cookie/Origin/UA 头。请求 URL 不超过 32KiB，表单不超过 32KiB，响应流不超过 512KiB；WebKit 返回值先复制为不超过 1MiB 的 JSON Data，再回到主线程解析，遵循 Swift 6 并发检查。平台错误继续使用有界脱敏说明。

生产 Cookie 仅从本次 `WKHTTPCookieStore` 读取，包括 HttpOnly，会话快照是权威状态；不会把 response body 里的 session 字符串或人工 Set-Cookie 转成账号凭据。已有有效 API 会话时，confirmed 返回的合法回调无需再次执行，仍必须验证账号资料；如存在不可信回调字段则拒绝。缺有效会话的回调交换、跨 origin 重定向及 2046 二次验证均明确暂未支持。

180 秒预算包含网页准备、二维码创建和确认等待。取得 confirmed 后，账号资料验证不会因为二维码后来过期而撤回一次已确认的会话。刷新、取消、失败、过期及成功均结束临时网页；取消与代次检查阻止迟到的创建、轮询和 Cookie 快照结果接入账号。现有账号资料与凭据提交流程还会检查 Task 取消和账号代次，关闭窗口后恢复此前账号。

本次新版完整回归通过 518 个测试、46 个套件（约 13.1 秒）；SDK 27 的弃用与接口审计通过，保留 warnings-as-errors 和 Swift 6 检查。正式 release 通过既有 Apple 开发者团队、bundle ID dev.byalpaca.music 的签名验证，MusicKit 仍开启，最低 macOS 26.0。匿名独立 WebKit 实测与注入测试均不是手机确认通过的证据；正式 App 启动与新二维码检查、真实确认结果另行记录。

正式 App 的首次启动检查发现，Foundation `URL.path` 会去掉有效端点的末尾 `/`，新 native 白名单因此在发送二维码请求前拦住了正确 URL。已改为比较 `URLComponents.percentEncodedPath`，仍严格只允许两条带末尾斜杠的官方端点；编码路径别名、跨域、其他端口、userinfo 与 fragment 均拒绝。新增实际 `URL.appending(path:)` 构造地址与危险变体的两项回归测试。此问题说明纯协议注入测试不能代替正式 App 的运行检查；发现时没有展示可扫码二维码，也没有要求用户重复确认。

路径修正后完整回归通过 520 个测试、46 个套件（约 14 秒），SDK 27 接口审计及正式签名构建再次通过；此前 518 项结果属于首次运行检查之前的版本。最终正式 UI 二维码与用户确认另行记录。

最终修正版已安装到正式路径；安装前核对源码与已验证构建哈希，安装后签名通过，原 App/源码均有备份，曲库文件哈希在安装期间保持不变。正式 App 重启后，网易云、QQ 与 Apple Music 账号状态恢复；当前《Night Dancer》的暂停位置、音量和视觉模式也保留。正式 UI 已实际显示新流程二维码，点击刷新后仍能重新显示，取消后返回音源页且三个已有来源正常。此为新版二维码创建、刷新和取消的真实界面验证；尚未有用户完成该版手机确认，不能称 2156 已解决或私人曲库已连接。

用户随后明确确认：已在该新版重新打开二维码，并在汽水音乐 App 确认，正式窗口仍返回错误 2156，平台说明仍为「系统繁忙，请重启应用或刷新页面后重试」。因此此次默认 WebKit 运行时补齐没有修复真实扫码确认；当前私人曲库尚未连接，不能用 520 项测试、SDK 请求签名存在、匿名 `new` 或二维码显示成功替代真人结果。官方同机客户端还未对照，SDK/WebKit 能力正常不能据此确定账号是否异常；原生 device/install 身份及完整官方登录组件初始化仍有未核实差异。停止要求在同一流程反复扫码，下一步需官方客户端的同账号对照。公开搜索、分享导入与标明试听的音频能力仍保持。
