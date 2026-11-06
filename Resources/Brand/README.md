# AlpacaMusic 品牌图标

AlpacaMusic 创作者：[byalpaca](https://byalpaca.dev)。本目录保存应用图标源图与生成记录。

## 当前图标

`AppIcon-Headphones.svg` 是应用图标的矢量源图：米白底色上戴蓝色头梁、红黄耳罩耳机的黑色羊驼，由项目作者提供。`scripts/make-icon.swift` 用 AppKit 按 16–1024 像素各尺寸直接绘制矢量图（套用 macOS 圆角图标外形），构建脚本再生成 `AppIcon.icns`。主界面标志直接复用 App 包里的 ICNS，和 Dock 使用同一份图像。

`MenuBarIcon-Headphones.svg` 是菜单栏图标：同一只羊驼的纯黑剪影，耳机只保留轮廓，周围留出透明间隙，按 18 × 18 点的模板图绘制，会随菜单栏的明暗自动变色。构建脚本把它原样复制为 App 包内的 `Contents/Resources/MenuBarIcon.svg`；没有该文件时（例如直接用 SwiftPM 运行）菜单栏回退为系统符号。

此目录仅用于构建，不属于 SwiftPM 的运行时资源。

## 备选与历史版本

`AppIcon-Bauhaus.png` 是上一版应用图标的方形 PNG 源图，采用米白、炭黑和红黄蓝的包豪斯配色，将长耳羊驼、耳机与唱片圆形结合，通过内置 imagegen 生成，提示词保存在 `app-icon-prompt.md`。`make-icon.swift` 仍可读取至少 1024 像素的方形 PNG。

`AppIcon-Bauhaus-Dog.png` 保留垂耳、圆鼻和笑脸，以相同的蓝色耳机及红黄唱片耳罩形成另一版头像。身体已改为短脖子、圆肩和浅色胸口。

`AppIcon-Bauhaus-Dog-Preview.png` 是修改身体之前的比较稿；`dog-preview-prompt.md` 记录生成及局部修改提示词。
