# 汽水音乐第三方接入调研

核验日期：2026-10-03。研究对象：AlpacaMusic 原生 macOS 客户端。来源为官方文档、官方 Mac 3.7.0 客户端静态资源、公开开源实现，以及用户参与的同机登录对照。没有导出官方客户端 Cookie 或账号凭据，没有调用需要开发者密钥的开放接口。

## 结论

**可见网页登录可以改善交互，但目前没有已核验的汽水消费者网页登录地址，不能通过换成网页弹窗直接解决现有登录失败。** 当前 AlpacaMusic 已使用 WebKit，只是显示自己的二维码和状态，并把网页视图隐藏；其真实网页是 API 根的 404 HTML，随后加载远程安全 SDK。这不等于加载了汽水官方完整登录页。

**官方 Mac 客户端能在同一台机器完成本账号登录。** 用户确认成功后，实际界面中的登录弹层消失并出现账号头像。因此应集中检查接入实现和运行环境差异，不能继续把 2156 简单归因于用户账号、确认太慢或暂时系统故障。这个对照没有证明 AlpacaMusic 的私人曲库或会员整曲已经可用。

**汽水确实存在公开官方 OpenAPI。** 之前“没有公开曲库 API 文档”的表述过宽，需更正。当前公开分类列出两个推荐接口，尚未找到第三方导入私人歌单、转接会员权益及原生 macOS 播放 SDK 的公开文档。

## 1. 网页弹窗是否可行

[汽水官网](https://www.qishui.com/) 当前提供下载入口，链接 `music.douyin.com` 标为“音乐人入驻”。歌曲分享 H5 可以显示公开内容，但未核验出可作为消费者账号登录和私人曲库入口的网页。音乐人平台、曲库任务平台和消费者播放器不可混为同一个授权入口。

[抖音网页授权](https://developer.open-douyin.com/docs/resource/zh-CN/dop/develop/sdk/web-app/web/permission) 是可用的正式授权方式：自有应用经过审核、登记 HTTPS 回调，用户在官方授权页扫码，取得 code 后换取开放平台 access_token。该凭证只覆盖获批 scope；没有找到将它换成汽水 PC session 的官方交换文档。

因此，不能借用第一方应用标识、把音乐人平台 Cookie 作为消费者授权，或把一个 404 页面显示出来就称为“官网登录”。如果平台批准 AlpacaMusic 的正式接入，才适合使用自有 ClientKey 和回调做可见网页授权。

## 2. 官方开放平台路线

| 文档能力 | 鉴权 | 已确认的范围 | 尚未验证 |
| --- | --- | --- | --- |
| [首页推荐](https://developer.open-douyin.com/docs/resource/zh-CN/dop/develop/openapi/qishui-music/feed-song-tab) | 应用级 client_token，scope `luna.openapi.platform.play_core` | 有正式接口文档；响应模型包含曲目、封面、歌词与 full/preview 播放字段 | 能力申请、实际播放数据、会员授权、播放器要求 |
| [相关歌曲推荐](https://developer.open-douyin.com/docs/resource/zh-CN/dop/develop/openapi/qishui-music/related-media) | 同上 | 可按起播内容和推荐场景请求推荐 | 不等于通用曲库搜索、私人歌单导入 |

这两个接口使用的是应用凭证，不能把普通用户 OAuth 的 access_token 直接代入。响应 schema 含有 `full` 字段，也不能证明普通开发者拿到接口后就能播放所有会员整曲。公开模型有 `user_id`、`auth_user_id`，但未说明与第三方 OAuth 身份的映射。

[入驻条件](https://developer.open-douyin.com/docs/resource/zh-CN/developer/join/join-into-developer-platform) 对个人主体列出的应用类型为小玩法、小游戏、小程序；企业主体列出移动、网站应用。[上线条件](https://developer.open-douyin.com/docs/resource/zh-CN/dop/develop/app-mgmt/pub-app) 要求官网 ICP 备案和主体匹配。汽水专项权限能否向个人、境外主体或 macOS 桌面播放器开放，公开文档没有给出答案。Apple Developer 资格不等同于抖音开放平台资格。

[官方密钥说明](https://developer.open-douyin.com/docs/resource/zh-CN/dop/develop/sdk/web-app/js/permission) 要求避免向客户端暴露 ClientSecret。正式接入应由 AlpacaMusic 的服务端保管密钥、处理 HTTPS 回调和凭证交换。这个服务由应用方运营，用户无需自己部署兼容服务；但它不会替代平台权限申请。

## 3. 同机官方登录对照与现有失败

此次从官网动态下载配置取得 Mac arm64 3.7.0 / build 1856，bundle 为 `com.soda.music`。只读挂载后，通过系统签名服务完成 deep/strict 验证，签名主体为 Beijing Bytedance Network Technology Co., Ltd.，团队 `JH23ZR9LF5`，有附带公证票据。校验后取得用户许可才运行；没有安装到 Applications。

官方窗口的实际指引为“汽水音乐 App → 搜索 → 搜索框右侧扫一扫”。用户自行完成协议选择和手机确认后，官方登录成功，界面显示账号入口。客户端还显示 3.8.0 更新提示，所以 3.7.0 是本轮固定审计样本，不应称为最新版本。对照后已正常退出并卸载临时镜像；官方自己的账号数据未导出或删除。

| 现象 | 对应阶段 | 可以得出的结论 |
| --- | --- | --- |
| “登录网页尚未就绪，或请求不属于官方登录接口” | AlpacaMusic 的本地发送条件检查 | 可能是会话未就绪或地址不符；没有提供服务器 2156 的证据 |
| 二维码创建及一次 `new` 轮询成功 | 匿名阶段 | 只能证明可以创建和查询挑战 |
| 手机确认后 2156，描述“系统繁忙” | 服务端确认阶段 | 本次确认没有取得可验证的账号连接；错误描述不等于已知根因 |
| 官方客户端同账号登录成功 | 官方消费者流程 | 本机、扫码入口及账号存在正常登录条件；支持继续核对实现差异 |

截图中的本地提示曾暴露 Foundation `URL.path` 去掉末尾斜杠的问题，已在此前构建改用 `percentEncodedPath` 并验证二维码创建、刷新、取消。当前实际窗口再核验显示的是 2156。不能仅凭新截图判断运行版本或把两个错误当成同一原因。

官方 `main.asar` 和 `app.asar` 与此前资源研究包逐字节一致。其启动还会取得 native `global_config` 的设备/安装上下文、执行 `TtWid.checkWebId()`，初始化消费者服务与账号组件。AlpacaMusic 的 API 404 + SDK Glue/BDMS 运行时未覆盖这套完整启动。**这是已发现的差异，尚未证明其中哪一项导致 2156。** 不应复制其他客户端的设备身份或静态签名来掩盖这个缺口。

## 4. 接入能力需要分开验收

| 能力 | AlpacaMusic 当前证据 | 仍需完成 |
| --- | --- | --- |
| 公开搜索、分享歌曲/歌单、封面、逐字歌词 | 已有匿名接口与实际应用验证 | 处理后续接口变化 |
| 公开音频 | 已验证普通试听与真实音频分析；按资源实际范围播放 | 逐曲区分整曲和试听，不扩大授权范围 |
| 汽水账号 | 默认 WebKit 创建成功，手机确认仍失败 | 完整登录与账号资料验证 |
| 私人歌单 | 有接入代码，没有本账号导入闭环 | 登录后分页、数据归属、导入和重启恢复 |
| 会员整曲 | 未完成 | 独立核验播放授权、签名、资源格式和播放器支持 |

此前完整构建的 520 项测试、SDK 27 审计及开发者签名验证仍只证明那版代码和构建通过检查，不能替代手机确认、私人曲库和会员播放的实际结果。以上为调研与官方对照时的基线；后续登录修订及其验证范围见第 7 节。

## 5. 第三方项目的实际实现

本轮固定读取默认分支 commit 和实际源码，未执行这些项目。表中“作者记录”与本应用的独立实测分开；项目的能力勾选表不能替代真人登录、私人歌单和整曲播放。

| 项目及固定版本 | 实际登录方法 | 对 AlpacaMusic 的参考价值与限制 |
| --- | --- | --- |
| [guowenye/qishui-api，e409c10](https://github.com/guowenye/qishui-api/blob/e409c10fe7441a10d370da7da61d62bbc1e5126c/src/qishuiClient.js) | 普通 HTTP 创建、轮询，确认时提取响应 Cookie | 有账号/私人列表端点，但 live-smoke 只验证二维码创建；没有当前完整确认的证据 |
| [guohuiyuan/music-lib，28e1080](https://github.com/guohuiyuan/music-lib/blob/28e1080ba4160a26af32f35c5b597f63e35fdba8/README.md) | 普通 HTTP，另有短信/MFA 和捕获参数输入 | 作者明确扫码未调通；私人歌单代码以已有有效 Cookie 为前提 |
| [libresoda，f02497e](https://github.com/sodahub-org/libresoda/blob/f02497e4c58502917812e2552a43c9e714226eb3/docs/QR-LOGIN.md) | Rust 控制 Chromium 的本地安全页面，每个 QR 独立浏览器上下文 | 作者有手机确认后取到浏览器会话的记录；实际实现依赖本地官方安全资产与浏览器特殊设置，不能等同于正常 WebKit 的官方网页弹窗 |
| [sodam，a15dff2](https://github.com/sodahub-org/sodam/blob/a15dff2fa9055f9836d1e159e59dc030da472136/crates/sodam-core/src/session.rs) | 桌面 UI 调用 libresoda，固定开启 CDP | 是具体第三方客户端参考；实际依赖 libresoda 04859085，需按锁定版本审核；会员取流仍有独立签名配置 |
| [MineRadio-api，2f7196b](https://github.com/zzstar101/MineRadio-api/blob/2f7196bedf02fd317a14d65cc1784045c685146b/src/qr_login/soda.rs) | reqwest 创建/轮询，确认响应 Cookie | 有私人列表代码，但还含固定设备标识和旧版参数；不能照搬后宣称已修复 2156 |
| [Mineradio-paused，d43de56](https://github.com/XxHuberrr/Mineradio-paused/blob/d43de565acabfdc1a9c9820a27e81a98ccbebcef/qishui-auth-v6.js) | 隐藏 Electron BrowserWindow，本地安全页面，QR/MFA | 已不是官网弹窗；源码关闭 webSecurity 并替换本地安全资产，还要独立处理会员播放 |

[libresoda 的 CDP 源码](https://github.com/sodahub-org/libresoda/blob/f02497e4c58502917812e2552a43c9e714226eb3/src/soda/cdp_signer.rs) 和上述 Mineradio 模块采用的特殊浏览器设置、本地官方安全资产与生成设备参数，需要分别评估技术、维护和分发许可，不能直接作为 AlpacaMusic 的依赖或正常 WebKit 成功的证明。本轮仅研究，没有引入这些资产、关闭安全保护或接入公共签名服务。

libresoda 的旧真机记录推荐原样通用 SDK QR，但本轮用户在该链接遇到 404；官方 3.7.0 的实际指引使用自己的 PC scan H5。因此不能只因社区写了“实测”就覆盖当前手机与官方客户端事实。

[Mineradio #451](https://github.com/XxHuberrr/Mineradio-paused/issues/451) 的用户报告账号及 VIP 已识别，但 `track_v2` 和搜索响应为空，无法播放。这支持把登录与播放分开验收；报告者对空响应原因的解释也仍是推断，不能视为官方定义。[libresoda 的取流报告](https://github.com/sodahub-org/libresoda/blob/f02497e4c58502917812e2552a43c9e714226eb3/docs/FULL-QUALITY-STREAM.md) 同样区分分享试听、应用级签名和加密资源，不能把分享音频默认当会员整曲。

另外，一个名为 Soda-Music 的仓库实际请求酷狗登录和曲库域名，已排除。项目名称、README 勾选或“OpenAPI”函数名都不是接口身份与权限的证据。

## 6. 下一步应验证什么

1. **正式接入资格和范围**：确认 `play_core` 是否接受 AlpacaMusic 的主体与 macOS 使用场景；询问是否另有消费者授权、收藏/私人歌单、会员播放与播放器接口。尚未代用户注册应用或联系平台。
2. **第一方流程的可实现差异**：在本应用独立会话内核验设备注册、Web ID、账号 SDK 初始化和正常会话交换。必须先有可核对的协议，不能猜字段；可见诊断窗口只能展示已核验的官方页面。
3. **分阶段验收**：确认手机登录 → 账号资料 → 私人歌单 → 一首官方可播歌曲的完整时长与权限 → 会话重启恢复。每一阶段保留具体失败原因。
4. **保留当前已验证能力**：公开搜索、分享导入和试听继续可用。消费者账号接入继续标为未接通，不再让用户反复扫同一个尚未修复的流程。

当前尚无已验证、可直接替换进去的消费者网页登录方案。正式开放能力值得优先确认；非官方 PC 接口路线仍需要补齐完整协议并承担持续维护。


## 7. 登录修订：独立 Web 身份初始化

官方 3.7.0 启动代码的 `TtWid` 使用 `aid=386088`、`service=api.qishui.com`、`host=https://api.qishui.com`、`union=false`、`needFid=false`。普通同源 JSON POST `/ttwid/check/` 携带 `fid=""`、`migrate_priority=0`；仅在业务码大于 1001 时调用 `/ttwid/register/`，传递本次 check 响应的 `migrate_info`。该流程不涉及把 WebID 当成 native `device_id`、`did` 或 `iid`。

用户批准的独立匿名验证 App 在全新、仅驻内存的 WebKit 中实测：check 返回 1002，register 返回 0，同一会话 recheck 返回 0。原生 Cookie store 确认服务器下发了 HttpOnly `ttwid`；网页的 `document.cookie` 看不到它是正常行为。随后真实远程 SDK 完成加载，二维码创建与一次 `new` 状态检查均成功。验证未展示二维码、未要求手机扫码、未读取官方 App 的现有账号，也未保存 Cookie 值或二维码 token。

随后将实际 staged `SodaWebLoginSession` 与 helper 直接编译进同一验证 App，再次完成 prepare → 二维码创建 → 一次 `new` 轮询 → 原生 Cookie 快照，全部成功，并确认 HttpOnly WebID 存在。这次验证执行的是待发布代码；用户手机确认仍未包含在匿名测试中。

当前修订把这一步加入 `SodaWebLoginSession.prepare()`，限定同源、正常浏览器安全策略、每次请求 3 秒、响应 64KiB 和至多三次请求。最终只有服务器检查码 0 才进入二维码阶段；其他码保留为初始化失败，不把未知状态推定为成功。与官方启动代码不等待 `checkWebId()` 不同，这里主动等待验证通过，以防身份初始化尚未完成便开始扫码。

扫码请求还补齐真实运行时的 `p_bd`、`p_zt`、`request_host`，并将本次生成的 trace ID 一致地用于查询、请求头与同源 trace Cookie。没有复制官方客户端的设备标识、签名或账号凭据。与此同时，修复已取消的旧刷新任务关闭新会话的竞态，区分浏览器进程终止、初始化未完成、请求地址无效和二维码过期。

完整 534 项测试（48 个套件）通过，包含直接执行实际 WebID 脚本的 JavaScriptCore 无网络状态测试；macOS 27 API 审计通过。发布构建保持 macOS 26 最低版本、原开发者证书指纹和 MusicKit 配置。

**上述匿名结果不能证明手机确认错误 2156 已解决。** 完整账号 SDK 的浏览器信息、native 设备/安装上下文仍有差异；必须以修改后 AlpacaMusic 的手机确认和账号资料验证为准。私人歌单与会员播放仍需分别验收。


### 手机确认复测结果

已将 WebID 修订签名安装至正式应用；重启后 Apple Music 保持授权，网易云与 QQ 保持连接，安装前后曲库文件校验相同。实际窗口的二维码创建和刷新正常。用户随后在汽水 App 确认，AlpacaMusic 再次返回 2156。因此已排除“只要补齐 WebID 就能修复”的假设，不能将第 7 节的匿名成功视为账号已连接。

进一步对比发现官方 `WebInterfaceSdk` 默认通过 Axios 的 XHR 发送请求，且无论创建还是轮询，都会附带每次登录上下文缓存的 `account_sdk_source_info`。这两个差异有源码依据，但仍不是 2156 的确定错误映射。后续修订需基于当前浏览器真实属性生成上下文，并保留真实运行验证与手机确认的独立结果。


### 账号请求上下文对齐

后续修订依据固定官方 3.7.0 renderer 的 `MG/jG` 数据流，在当前 WebKit 中读取普通浏览器属性，按官方 `w7` 的 UTF-8 字节 XOR 5 / 十六进制格式编码并缓存，仅用于本会话请求的 `account_sdk_source_info`。使用官方可配置的 `useBitReport=false` 分支，`bit_protocol` 为空字符串；不探测第三方自定义协议、不伪造应用目录或自动化状态、不填入其他客户端的设备身份。

正常 XHR 替换了 passport fetch 适配器，继续使用同一 WebKit 的 Cookie 和远程安全 SDK。保留取消、请求超时、响应字节上限，以及返回地址的同源/路径核验。XHR 重定向由浏览器及正常 CORS 策略管理；不能声称具备 fetch `redirect:error` 的预先拒绝语义。trace Cookie 对齐到平台父域 `qishui.com`，轮询 query 补齐与官方相同的 `is_new_login=1`（表单原本已有）。

公开可读代码没有证明 XHR 与 fetch 的签名必然不同，也没有证明新增上下文本身足以修复 2156。本修订不增加社区项目中的固定设备值、手写 `x-ss-stub` 或猜测的 appKey 派生签名；官方实际配置没有 appKey，相关分支不会启用。


包含上下文采集、XHR、WebID 和最新查询参数的实际后端已再次编译进获准的匿名验证 App：prepare、HttpOnly WebID、二维码创建 HTTP 200/业务码 0、一次轮询 HTTP 200/业务码 0/`new`、Cookie 快照均通过。独立 XHR 适配器 12 场景无网络检查通过，完整 538 项测试/49 套件与 SDK 27 审计通过；发布签名仍匹配原团队和 bundle ID。正式新版再次由用户用汽水 App 扫码确认，实际 AlpacaMusic 窗口仍返回 2156。前后两版均未通过手机确认，账号未连接；不得把这些测试和匿名成功写成登录修复成功。


### 本轮最终状态与继续调试的边界

- 已更新并运行：独立 WebID 初始化、当前浏览器信息、XHR 请求及一致的关联参数、取消竞态、期限与进程中断错误处理。现有三个已连接平台和曲库保留。
- 已实测通过：完整 538 项测试、SDK 27 审计、原开发者身份签名、匿名创建与查询、正式应用启动及二维码生成。
- 已实测失败：用户完成两轮不同修订的手机确认后，均返回 2156；没有取得可验证账号会话。私人歌单与会员整曲也因此未完成验收。
- 尚未核实：官方 native global_config 中 device/install 上下文的独立初始化协议，以及服务端对本次确认的具体拒绝条件。完整消费者 Account SDK 为依赖主程序的 bundled ESM，未找到可直接用于本应用的独立托管账号组件。已经补齐的普通浏览器字段不等于复现了全部原生上下文。

下一步应先取得可核对的原生设备初始化或实际确认请求差异，再实施有依据的修改。没有错误码映射时不能断言账号异常、等待太慢、服务器暂忙、某个签名失败或设备 ID 必然是根因。当前停止要求用户重复扫码；没有创建后台重试或定时任务。
