# Artwork-preserving point clouds / 保留封面结构的点云

## 中文

点云封面使用本地生成算法，将封面的颜色、浅浮雕与细节保护分开处理。目标是在音乐驱动的粒子动态中保留原图的构图、文字、线条和颜色。它生成艺术化浅浮雕，不推断真实场景的三维深度，也不调用外部图像或 AI 服务。

生成与渲染流程：

1. 对每个采样单元做面积加权积分，在线性 RGB 中处理颜色，并保留预乘透明度的覆盖率。这样比只读取单个像素更能避免细线、纹理在低密度点云中丢失或产生摩尔纹。
2. 用色彩差异、单元内细节和透明边缘建立保护权重。文字、轮廓和等亮度但颜色不同的边界都会得到保护。
3. 用多尺度明暗结构生成有限的浅浮雕。不会将低对比度的细微噪点归一化成完整深度；均匀颜色保持平面。
4. 粒子大小随采样间距和投影尺寸变化。封面主体用普通透明度混合，少量辉光作为独立底层，避免把原图颜色直接叠加成过曝亮斑。
5. 节拍与持续波动保持小幅、连贯的位移；细节保护权重进一步减小文字和轮廓的局部拉扯。换曲时，粒子从各自附近聚合，保留封面的整体位置。

现有密度、浮雕深度、颗粒大小、波动和辉光设置继续可用。只有可获得 PCM 的播放来源驱动节拍和能量；暂停或“减少动态”时不产生音频驱动的运动。

验证覆盖透明边缘、线性颜色积分、细线采样、微弱对比度、浅浮雕范围、确定性、取消处理和 GPU 位移边界。实际 Metal 对比图用于检查识别度；数值检查不能替代不同封面的视觉评审。

## English

Artwork point clouds use a local algorithm that treats color, shallow relief, and detail protection separately. The goal is to retain composition, lettering, lines, and color during music-driven particle motion. This produces an artistic relief, not reconstructed scene depth, and does not call an external image or AI service.

Generation and rendering:

1. Integrate each sampling cell by area in linear RGB, retaining premultiplied-alpha coverage. This avoids the loss and aliasing of narrow lines and textures caused by sampling a single pixel.
2. Derive protection weights from color differences, within-cell detail, and alpha boundaries. This also protects boundaries with similar luminance but different colors.
3. Build bounded shallow relief from multiscale tonal structure. Small low-contrast noise is never stretched into the full depth range; uniform colors stay flat.
4. Size particles relative to sampling spacing and projected scale. Render the artwork core with ordinary alpha compositing and a separate faint glow underlay, preserving photographic color instead of accumulating bright spots.
5. Keep beat accents and continuous waves small and coherent. Detail weights further restrain local movement around lettering and outlines. During track changes, particles assemble from nearby positions.

Existing density, relief, particle size, motion, and glow settings remain available. Beat and energy require usable PCM. Paused playback and Reduce Motion do not produce audio-driven movement.

Validation covers transparent boundaries, linear color integration, fine-line sampling, weak contrast, relief bounds, determinism, cancellation, and GPU displacement bounds. Actual Metal comparison renders support visual review; numeric checks cannot replace review across different artwork.

## Design references / 设计参考

- [Surface Splatting — ETH Zürich](https://cgl.ethz.ch/research/past_projects/surfels/surfacesplatting/index.html): point sampling and reconstruction filtering. This implementation uses circular point sprites and area-prefiltered artwork; it does not implement the paper’s full anisotropic EWA pipeline.
- [Guided Image Filtering — He, Sun, Tang](https://people.csail.mit.edu/kaiming/publications/pami12guidedfilter.pdf): structure-aware filtering. The artwork algorithm is independently implemented and uses its own multiscale relief and detail weights; it is not a copy of the guided filter.
