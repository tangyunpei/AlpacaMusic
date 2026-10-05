# Security Policy / 安全政策

[English](#english) · [简体中文](#简体中文)

<a id="english"></a>
## English

### Supported versions

Security fixes target the latest published release and the current `main` branch. Older releases do not receive separate backports. AlpacaMusic is maintained by byalpaca (Junpei Tang); response and remediation times depend on the issue and maintainer availability.

### Report a vulnerability privately

Use [GitHub's private vulnerability reporting form](https://github.com/tangyunpei/AlpacaMusic/security/advisories/new), also available under **Security → Report a vulnerability**. Please avoid public issues for vulnerabilities that expose accounts, credentials, private files, or other users' data. If the private form is unavailable, open an issue asking for a private reporting channel without publishing vulnerability details.

Include the affected version or commit, macOS version, impact, and minimal reproduction steps. A proof of concept should use test accounts and synthetic data. Remove passwords, cookies, access and refresh tokens, signing keys, account identifiers, private library exports, and personal paths from logs or screenshots. Never send real credentials to demonstrate an issue. If a credential has already leaked, revoke or rotate it through its issuer immediately.

Test only systems, accounts, and files that you own or have permission to assess. Do not probe music providers, other users, or third-party services on the project's behalf. Coordinate public disclosure with the maintainer after assessment and a fix or mitigation where possible. Routine playback errors, unavailable tracks, and feature requests can be reported in public issues after removing personal information.

### Repository and release safeguards

CI uses hosted runners, limited token permissions, and Actions pinned to full commit hashes. Pull request tests do not need account sessions, developer certificates, or notarization credentials. Release installers are published separately; CI does not sign or automatically publish installers. Download installers from this repository's Releases page and retain macOS signature and Gatekeeper checks.

The Swift tests and SDK API audit use the hosted `xcode-27` runner. Its availability and toolchain are checked by CI. CodeQL scans GitHub Actions and Python scripts. Swift scanning is deferred because the project's Swift 6.4 requirement exceeds the [currently documented CodeQL Swift support range](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/). Passing checks do not establish that the application or third-party platform integrations have received a complete security audit.

See the [Disclaimer](DISCLAIMER.md#english) for account, local data, and third-party service boundaries, and the [Third-party notices](THIRD_PARTY_NOTICES.md#english) for external components.

---

<a id="简体中文"></a>
## 简体中文

### 支持的版本

安全修复面向最新发布版本及当前 `main` 分支，旧版本不单独维护安全补丁。AlpacaMusic 由 byalpaca（Junpei Tang）维护；响应与修复时间取决于问题及维护者的可用时间。

### 私下报告漏洞

请使用 [GitHub 私密漏洞报告表单](https://github.com/tangyunpei/AlpacaMusic/security/advisories/new)，也可从 **Security → Report a vulnerability** 进入。涉及账号、凭据、私人文件或其他用户数据的漏洞，请避免在公开 Issue 中披露。若私密表单不可用，请只提交请求私密反馈渠道的 Issue，不公开漏洞细节。

请提供受影响的版本或提交、macOS 版本、影响及最小复现步骤。验证示例应使用测试账号和合成数据；日志与截图请移除密码、Cookie、访问及刷新令牌、签名私钥、账号标识、私人曲库导出和个人路径。请勿发送真实凭据证明问题；若凭据已经泄露，应立即通过签发平台撤销或轮换。

请仅测试你拥有或已获授权评估的系统、账号和文件。请勿代表本项目探测音乐平台、其他用户或第三方服务。尽可能在评估并提供修复或缓解措施后，与维护者协调公开披露。普通播放错误、不可用曲目及功能建议可在移除个人信息后通过公开 Issue 反馈。

### 仓库与发布保护

CI 使用托管运行环境、有限的令牌权限和固定完整提交哈希的 Actions。PR 测试无需账号会话、开发者证书或公证凭据。安装包单独发布，CI 不签名或自动发布安装包。请从本仓库 Releases 下载，并保留 macOS 签名及 Gatekeeper 检查。

Swift 测试和 SDK API 审计使用托管 `xcode-27` 环境，由 CI 核验环境可用性与工具链。CodeQL 扫描 GitHub Actions 和 Python 脚本；由于项目要求 Swift 6.4，超出 [CodeQL 目前文档列出的 Swift 支持范围](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/)，暂缓启用 Swift 扫描。检查通过不代表应用或第三方平台接入已完成全面安全审计。

账号、本地数据与第三方服务边界见[免责声明](DISCLAIMER.md#简体中文)，外部组件见[第三方声明](THIRD_PARTY_NOTICES.md#简体中文)。
