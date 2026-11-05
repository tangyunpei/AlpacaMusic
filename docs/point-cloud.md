# Painterly artwork point clouds / 写意封面点云

## 中文

点云封面从原图提取主色和大轮廓，再生成有疏密、留白和颗粒层次的写意画面。默认抽象程度为 0.2：保留更清晰的封面轮廓与字形，同时加入不规则颗粒和适量留白。它生成艺术化浅浮雕，不推断真实场景的三维深度，也不调用外部图像或 AI 服务。

生成与渲染流程：

1. 对每个采样单元做面积加权积分，在线性 RGB 中处理颜色，并保留透明度的覆盖率。抽象程度为 0 时使用精细采样，保留原图文字、线条和纹理。
2. 在不同尺度上过滤颜色，并在 OKLab 色域中提取最多六种来自封面的颜料色。柔性混色保持主色关系，降低细碎纹理和小字的权重。
3. 用大色区与周边颜色的差异、宽尺度轮廓和连续的低频空间场共同控制疏密。留白按区域形成；外围逐渐消散，避免完整的矩形像素板。
4. 将颗粒分为主体色团的中大颗粒、轮廓的细颗粒和外围尘点。确定性的格内抖动与有限流场偏移打散网格；同一歌曲和设置生成稳定的画面，不逐帧重新随机。
5. 用粗尺度结构和区域相位生成有限的浅浮雕。主体使用普通透明度混合；独立的少量辉光集中在色团和轮廓，避免背景尘点糊成亮片。
6. 节拍与持续波动按区域连贯变化，局部位移有明确上限。换曲时颗粒从各自附近聚合；拖动抽象滑块时保留当前点云，合并频繁更新后再替换。

在“调整视觉效果”中使用“抽象程度”：0 接近精细封面，0.2 为默认效果，0.55 是更写意的中间档，细字和纹理会更多地融入色团，0.85 及以上更松散。该值可保存到预设；旧设置与旧预设保留原有参数，并为新控制补入默认值。现有密度、浮雕深度、颗粒大小、波动和辉光设置继续可用。只有可获得 PCM 的播放来源驱动节拍和能量；暂停或“减少动态”时不产生音频驱动的运动。

验证覆盖透明边缘、线性颜色积分、精细端兼容、细节弱化、主色保留、粒径层次、不同密度下的疏密一致性、确定性、取消处理、旧设置迁移和 GPU 位移边界。另使用实际 Metal 渲染比较人像与文字测试图、包豪斯图标和原创试听封面；动态样片使用注明的合成节奏，验证运动与暂停冻结，不代表实曲节拍准确性。数值检查不能替代不同封面的视觉评审。

## English

Artwork point clouds extract dominant colors and broad forms from the source, then build a painterly composition with clusters, negative space, and varied grains. The default abstraction is 0.2: source contours and lettering remain more recognizable while irregular grains and some negative space soften the image. This is an artistic relief, not reconstructed scene depth, and does not call an external image or AI service.

Generation and rendering:

1. Integrate each sampling cell by area in linear RGB, retaining alpha coverage. At abstraction 0, detailed sampling retains source lettering, lines, and textures.
2. Filter color at multiple scales and extract up to six artwork-derived pigments in OKLab space. Soft palette blending keeps the main hues while reducing fine textures and small type.
3. Combine differences between broad color regions and the outer field, coarse contours, and a continuous low-frequency spatial field to control density. Vacancies form regions, and the perimeter dissolves instead of retaining a solid rectangular pixel board.
4. Use medium and large grains for pigment bodies, finer grains for contours, and dust at the perimeter. Deterministic cell jitter and bounded flow offsets remove the grid. The same song and settings produce stable geometry without new randomization each frame.
5. Build bounded shallow relief from coarse structure and region phase. Use ordinary alpha compositing for the core, with faint glow concentrated on pigment bodies and contours rather than flat background dust.
6. Keep beat accents and continuous waves coherent within regions, with bounded local displacement. Particles assemble from nearby positions on track changes. Abstraction-slider updates are coalesced while the current cloud stays visible.

Use “Abstraction” in “Adjust Visual Effects”: 0 is close to detailed artwork, 0.2 is the default, 0.55 offers a more painterly middle setting where small lettering and textures blend further into pigment regions, and 0.85 or above is looser. Presets retain this value; old preferences and presets preserve their existing parameters and receive the new default. Existing density, relief, particle size, motion, and glow settings remain available. Beat and energy require usable PCM. Paused playback and Reduce Motion do not produce audio-driven movement.

Validation covers alpha boundaries, linear color integration, faithful-endpoint compatibility, detail suppression, main hues, grain hierarchy, density-tier consistency, determinism, cancellation, preference migration, and GPU displacement bounds. Actual Metal comparisons use a portrait-and-type fixture, the Bauhaus icon, and original demo artwork. The motion study uses explicitly synthetic rhythm to verify motion and pause freezing, not real-song beat accuracy. Numeric checks cannot replace visual review across different artwork.

## Design references / 设计参考

- [Surface Splatting — ETH Zürich](https://cgl.ethz.ch/research/past_projects/surfels/surfacesplatting/index.html): point sampling and reconstruction filtering. This implementation uses circular point sprites and area-prefiltered artwork; it does not implement the paper’s full anisotropic EWA pipeline.
- [Guided Image Filtering — He, Sun, Tang](https://people.csail.mit.edu/kaiming/publications/pami12guidedfilter.pdf): structure-aware filtering. The artwork algorithm is independently implemented and uses its own multiscale relief and detail weights; it is not a copy of the guided filter.
- [Weighted Voronoi Stippling — Adrian Secord](https://www.cs.ubc.ca/labs/imager/tr/2002/secord2002b/secord.2002b.pdf): content-dependent point density / 随内容变化的点密度。The implementation uses a bounded, jittered sampling field, not the paper’s full Voronoi relaxation / 本实现使用有限偏移采样场，未实现论文的完整 Voronoi 松弛流程。
- [Flow-Based Image Abstraction — Kang, Lee, Chui](https://www.umsl.edu/~kangh/Papers/kang_tvcg09.pdf): coherent image abstraction / 连贯的图像抽象。The implementation combines coarse color structure with its own spatial curl field; it does not reproduce the paper’s edge-tangent flow algorithm / 本实现结合粗尺度色域和独立空间旋流场，未复现论文的边缘切向流算法。
