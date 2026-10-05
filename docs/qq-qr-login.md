# QQ 音乐应用内扫码登录（2026-10-04）

应用内 QQ / 微信选择器直接承载官方授权组件，不再先打开 QQ 音乐首页，也不要求用户手动点击「连接曲库」。授权范围和平台确认界面保留，应用不代替用户同意协议或手机确认。

## 当前官网依据

2026-10-04 匿名读取以下官方页面与脚本，未扫码、未读取任何已有账号：

- [QQ 音乐官网](https://y.qq.com/n/ryqq/)
- [官网公共组件](https://y.qq.com/ryqq/js/common.chunk.80d50705ce8f47a01eb5.js)：QQ `https://graph.qq.com/oauth2.0/authorize` 使用 `client_id=100497308`、`response_type=code`、`display=pc`、`scope=get_user_info,get_app_friends`；微信 `https://open.weixin.qq.com/connect/qrconnect` 使用 `appid=wx48db31d50e334801`、`scope=snsapi_login`，以及官方 `popup_wechat.css`。
- [官网换票页](https://y.qq.com/portal/wx_redirect.html)：根据 `login_type=1/2`，分别通过 `QQConnectLogin.LoginServer / QQLogin` 和 `music.login.LoginServer / Login` 把授权码兑换为 QQ 音乐自己的会话，随后跳回 `surl`。
- 官方 QQ 授权页面会显示 QQ 扫码组件和授权范围；不能只复制二维码、丢弃随后授权及换票步骤。官方微信组件支持 `fast_login=0`，用于明确扫码、关闭本机微信快捷登录探测。

这些公开端点目前仍可匿名返回页面。读取脚本不等于真实手机扫码端到端登录成功。

## 会话约束

每次打开、刷新、切换 QQ / 微信创建全新的非持久化 WebKit 数据容器，不复制 Safari、Chrome、其他 App 或 AlpacaMusic 已保存账号。关闭后停止加载并清理临时数据。

每代二维码绑定随机 `state`；回调必须是确切 HTTPS `y.qq.com/portal/wx_redirect.html`，包含本代 state、所选登录类型、固定官网返回地址和单一有效 code。交由官方页面原有脚本完成换票。应用不读取密码、不自行交易授权码、不输出 Cookie、授权 URL、code、state 或原始平台错误。

官方完成换票后，应用只读取此窗口中属于 QQ 音乐的允许名单 Cookie；必须同时有有效账号标识和音乐专用票据（`qqmusic_key` 等），普通 QQ `skey/p_skey` 不代表登录完成。真正连接仍调用现有 QQDirectProvider 本人资料校验，校验通过才持久化。官网返回首页的导航会拦截，保留紧凑登录界面。二维码等待最长十分钟，刷新、切换和取消均废弃旧代次，异步迟到结果不能用于连接。

## 验证边界

新增测试覆盖官方 URL、两种登录类型、state 代次绑定、重复参数拒绝、精确回调/返回地址、仅 QQ 中间票据不算成功、音乐会话作用域/有效期、账号格式及取消后的结果拒绝。实际手机扫码及平台额外确认仍必须由用户完成，不能以匿名页面检查或测试声称已经完成 QQ / 微信真实授权。
