# Security Policy / 安全政策

[English](#english) · [简体中文](#简体中文)

<a id="english"></a>
## English

### Supported versions

Security fixes target the latest published release and the current `main` branch. Older releases do not receive separate backports. AlpacaMusic is maintained by byalpaca; response and remediation times depend on the issue and maintainer availability.

### Report a vulnerability privately

Use [GitHub's private vulnerability reporting form](https://github.com/tangyunpei/AlpacaMusic/security/advisories/new), also available under **Security → Report a vulnerability**. Please avoid public issues for vulnerabilities that expose accounts, credentials, private files, or other users' data. If the private form is unavailable, open an issue asking for a private reporting channel without publishing vulnerability details.

Include the affected version or commit, macOS version, impact, and minimal reproduction steps. A proof of concept should use test accounts and synthetic data. Remove passwords, cookies, access and refresh tokens, signing keys, account identifiers, private library exports, and personal paths from logs or screenshots. Never send real credentials to demonstrate an issue. If a credential has already leaked, revoke or rotate it through its issuer immediately.

Test only systems, accounts, and files that you own or have permission to assess. Do not probe music providers, other users, or third-party services on the project's behalf. Coordinate public disclosure with the maintainer after assessment and a fix or mitigation where possible. Routine playback errors, unavailable tracks, and feature requests can be reported in public issues after removing personal information.

### Repository and release safeguards

The repository runs no GitHub Actions workflows. Tests run locally and do not need account sessions, developer certificates, or notarization credentials. Release installers are published separately; nothing signs or publishes installers automatically. Download installers from this repository's Releases page and retain macOS signature and Gatekeeper checks.

Every check (build script tests, translations, the Swift tests and the SDK API audit) runs locally with `scripts/check-all.sh` before a merge; GitHub runs no CI or CodeQL scans. GitHub secret scanning and push protection stay enabled. Passing checks do not establish that the application or third-party platform integrations have received a complete security audit.

See the [Disclaimer](DISCLAIMER.md#english) for account, local data, and third-party service boundaries, and the [Third-party notices](THIRD_PARTY_NOTICES.md#english) for external components.

---

<a id="简体中文"></a>
## 简体中文

### 支持的版本

安全修复面向最新发布版本及当前 `main` 分支，旧版本不单独维护安全补丁。AlpacaMusic 由 byalpaca 维护；响应与修复时间取决于问题及维护者的可用时间。

### 私下报告漏洞

请使用 [GitHub 私密漏洞报告表单](https://github.com/tangyunpei/AlpacaMusic/security/advisories/new)，也可从 **Security → Report a vulnerability** 进入。涉及账号、凭据、私人文件或其他用户数据的漏洞，请避免在公开 Issue 中披露。若私密表单不可用，请只提交请求私密反馈渠道的 Issue，不公开漏洞细节。

请提供受影响的版本或提交、macOS 版本、影响及最小复现步骤。验证示例应使用测试账号和合成数据；日志与截图请移除密码、Cookie、访问及刷新令牌、签名私钥、账号标识、私人曲库导出和个人路径。请勿发送真实凭据证明问题；若凭据已经泄露，应立即通过签发平台撤销或轮换。

请仅测试你拥有或已获授权评估的系统、账号和文件。请勿代表本项目探测音乐平台、其他用户或第三方服务。尽可能在评估并提供修复或缓解措施后，与维护者协调公开披露。普通播放错误、不可用曲目及功能建议可在移除个人信息后通过公开 Issue 反馈。

### 仓库与发布保护

仓库不运行 GitHub Actions 工作流。测试在本机运行，无需账号会话、开发者证书或公证凭据。安装包单独发布，不会被自动签名或发布。请从本仓库 Releases 下载，并保留 macOS 签名及 Gatekeeper 检查。

合并前通过 `scripts/check-all.sh` 在本机运行全部检查（构建脚本测试、翻译检查、Swift 测试和 SDK API 审计）；GitHub 不运行 CI 或 CodeQL 扫描。GitHub 机密扫描及推送保护保持启用。检查通过不代表应用或第三方平台接入已完成全面安全审计。

账号、本地数据与第三方服务边界见[免责声明](DISCLAIMER.md#简体中文)，外部组件见[第三方声明](THIRD_PARTY_NOTICES.md#简体中文)。
