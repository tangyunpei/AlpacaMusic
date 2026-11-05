# Localization / 多语言

## English

AlpacaMusic supports **English** and **Simplified Chinese**, with **Follow System** as the default. Open **Settings → Language** to switch immediately. The selection is saved; playback, lyrics, input fields, queue, and visualizations keep their state.

App-authored navigation, menus, controls, accessibility descriptions, visual settings, login/import flows, and diagnostics use the same language resources. Track titles, lyrics, usernames, playlist names, and custom preset names remain as received or entered. A transient message that was already generated may keep its event language; subsequent messages use the current selection. Official login pages and system permission panels use their own language settings. Both system permission descriptions are bundled in English and Simplified Chinese.

These changes are included in the **0.1.11 release** and newer source builds.

For contributors:

- Use `L10n.string("…")` with a literal `String.LocalizationValue`, preserving typed Swift interpolation. Do not translate protocol values, stored identifiers, comparison strings, or user content.
- Keep `Sources/AlpacaMusic/Localization/{en,zh-Hans}.lproj/Localizable.strings` aligned. English plural rules live in `en.lproj/Localizable.stringsdict`; app permission text lives in `Resources/Localization/*/InfoPlist.strings` and is copied into the app bundle.
- Run `python3 scripts/check-localizations.py`, `swift test --filter LocalizationTests`, and the normal regression suite. After a Swift build with `-Xswiftc -emit-localized-strings`, run the checker with `--extracted-dir .build` to verify actual compiler keys as well as placeholder types. SwiftBuild writes `.stringsdata` within the build directory.
- Adding another language also requires extending `AppLanguage`, supported-language negotiation, bundle metadata/resources, and tests. Do not claim support until translations and runtime layout have been checked.

This follows Apple's [localized package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources) and [typed localization values](https://developer.apple.com/documentation/swift/string/localizationvalue).

## 简体中文

AlpacaMusic 支持**简体中文**和**英文**，默认**跟随系统**。在**设置 → 语言**中可即时切换，选择会保存；播放、歌词、输入框、队列和视觉效果保留当前状态。

应用自带的导航、菜单、控件、无障碍描述、视觉设置、登录与导入流程及诊断提示使用统一语言资源。歌名、歌词、用户名、歌单名称和自定义预设名称保持原样。已生成的临时提示可能保留产生时的语言，后续提示使用当前选择。官方登录网页和系统权限窗口使用各自的语言设置；两项系统权限说明已打包中英文版本。

**0.1.11 发布版本**及后续源码构建已包含这些更新。

开发者注意：

- 界面文字使用 `L10n.string("…")` 和保留参数类型的 Swift 插值；协议字段、持久化标识、用于解析与比较的字符串和用户内容不可翻译。
- 两种语言的 `Localizable.strings` 保持键一致，英文单复数使用 `Localizable.stringsdict`。系统权限说明位于 `Resources/Localization/*/InfoPlist.strings`，打包时复制到主 App 资源中。
- 执行语言资源检查、`LocalizationTests` 和常规回归测试；编译时启用字符串提取，再以 `--extracted-dir .build` 检查编译器实际提取的键和参数类型。
- 新增语种需同步扩展语言选择、协商规则、资源与包元数据、测试，并检查实际显示布局。
