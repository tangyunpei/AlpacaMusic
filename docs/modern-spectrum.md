# Continuous spectrum / 连续竖条频谱

The vertical spectrum uses 72 slim continuous rounded columns, blue bodies, cyan-white tips, restrained glow and warm color reserved for tall measured peaks. The inactive segmented wall is removed. Silence and unavailable PCM show a quiet baseline, without invented columns.

竖条频谱采用 72 根纤细连续圆角柱：蓝色主体、青白色顶端与克制辉光，只有较高的真实峰值使用少量暖色。未点亮的分段格墙已移除，静音或缺少 PCM 时仅保留安静基线，不生成假柱形。

Frequency spacing, fixed dB response, attack/release, peak hold, pause/resume and reduced-motion behavior use the existing signal and motion pipeline. Comparison images use identical measured FFT and presentation frames, drawn through the previous and current Canvas renderers. The original synthetic PCM fixture is processed by production audio analysis; it does not read accounts, song libraries or audio devices.

频率间距、固定 dB 响应、起落速度、峰值保持、暂停恢复和减少动态行为沿用原有信号与动态逻辑。对照图使用相同实测 FFT 与呈现状态，分别经过旧版和新版 Canvas 绘制。原创合成 PCM 经生产音频分析处理，不读取账号、曲库或音频设备。

Regression checks cover continuous column rendering, absence of a dormant lattice, real frequency mapping, amplitude scaling, held peaks and frozen poses. Rendering evidence does not establish PCM availability for Apple Music or Spotify, and does not imply user approval of the visual design.

回归检查覆盖连续柱形、静音无格墙、真实频率映射、电平尺度、峰值保持与暂停冻结。绘制验证不能证明 Apple Music 或 Spotify 的 PCM 可用，也不代表用户已经认可视觉设计。
