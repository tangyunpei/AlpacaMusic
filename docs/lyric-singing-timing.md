# Singing cadence estimates / 歌词语速估算

Line-only LRC commonly closes a lyric at the next line's onset. Spreading that whole interval over every character also allocates sustained final vowels and instrumental gaps to earlier syllables. The shared schedule now estimates a local pronunciation cadence from up to eight neighboring cues, preferring valid supplied word onsets. It excludes the current cue from that estimate and rejects unusually sparse neighbors. Short, dense phrases still fit within their original interval. The final spoken unit keeps the remaining tail; earlier onsets do not move later merely because that tail grows. Sentence-final punctuation appears when articulation finishes.

普通 LRC 常以“下一句开始”作为本句结束；将整个间隔平均分配给每个字，会把尾音与间奏分配到前面的音节。新的共享时序最多参考八条邻句，优先使用有效的逐词起点估计局部发音速度；当前句不会影响自己的语速估算，过于稀疏的邻句被排除。快速密集歌词仍在原句间隔内完成，末字承接剩余尾音，前面的字不会因为尾音变长而整体推迟。句末标点随语句完成出现。

Scrolling highlights, kinetic compositions, long-line reading layouts, echoes and local accents share the same context and schedule. Cache keys include that context, and a bounded neighbor cache avoids reanalyzing lyrics every animation frame. Real single-character provider timestamps remain authoritative; only internal timing of multi-character fragments is estimated, within their supplied boundaries. Latin-script text continues to appear by whole word. Seeks reconstruct the same schedule without retaining playback history.

滚动高亮、动态字幕、长句阅读布局、回声与局部强调使用相同语速上下文和时序。缓存键包含上下文，有界邻句缓存避免每帧重复分析。提供方的真实单字起止时间保持原值，多字片段仅在原始边界内估算内部时间。英语、西语等仍整词出现；拖动回放会重建相同时间表，不依赖播放历史。

This remains a lyric-timestamp/text estimate, not vocal recognition or guaranteed word-accurate synchronization. It does not shift source line timestamps or create word timestamps in the lyric document. The reported QQ recording was checked against its anonymous public LRC intervals: the first reported cue's final-character estimate moved from 26.11 s to 25.01 s while retaining its 26.54 s cue end. This is a schedule comparison, not a measured vocal-alignment result. Regression neighbors use original placeholders with the same character counts, not the complete song lyrics.

这仍属于歌词时间轴与文本估算，不是人声识别，也不能保证逐字精确同步。原始句起点与歌词文档保持不变，不向文档写入伪造的逐字时间。用户报告的 QQ 音乐版本已按匿名公开 LRC 间隔核对：首处报告歌词的末字估算从 26.11 秒提前至 25.01 秒，句终点仍为 26.54 秒。这是时序比较，不能视作实际人声对齐测量。回归用例的邻句采用同字数的原创占位文本，不保存整首歌词。
