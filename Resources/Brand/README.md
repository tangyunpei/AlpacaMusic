# AlpacaMusic 品牌图标

AlpacaMusic 创作者：[byalpaca](https://byalpaca.dev)（Junpei Tang）。本目录保存应用图标源图与生成记录。

`AppIcon-Bauhaus.png` 是新应用图标的方形源图。图标采用米白、炭黑和红黄蓝的包豪斯配色，将长耳羊驼、耳机与唱片圆形结合。

通过内置 imagegen 生成，源文件为 PNG，没有 SVG 矢量源文件。采用简化色块和清晰轮廓，设计提示词保存在 `app-icon-prompt.md`。

`scripts/make-icon.swift` 读取源图，用 sRGB 和高质量缩放生成 macOS 所需的 16–1024 像素图标，再由构建脚本生成 `AppIcon.icns`。主界面标志直接复用 App 包里的 ICNS，和 Dock 使用同一份图像。此目录仅用于构建，不属于 SwiftPM 的运行时资源。
# 狗版备选

`AppIcon-Bauhaus-Dog.png` 保留垂耳、圆鼻和笑脸，以相同的蓝色耳机及红黄唱片耳罩形成另一版头像。身体已改为短脖子、圆肩和浅色胸口。用户要求两版保留，目前正式构建仍使用羊驼版。

`AppIcon-Bauhaus-Dog-Preview.png` 是修改身体之前的比较稿；`dog-preview-prompt.md` 记录生成及局部修改提示词。
