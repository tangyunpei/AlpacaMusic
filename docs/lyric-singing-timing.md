# Singing cadence estimates / 歌词语速估算

Line-only lyrics (LRC, LRCLIB, every Apple Music song) give a start for each line, and the line usually ends where the next one starts. To light up each word, the app estimates when it is sung from the text alone. The estimate was measured against 160 NetEase songs (Chinese, Japanese, English and a few Korean) that also have word-timed YRC. Their real LRC line times were the input; the YRC word onsets were the truth.

纯逐行歌词（LRC、LRCLIB，以及所有 Apple Music 歌曲）只给出每句的开始时间，句子通常在下一句开始时结束。为了逐字点亮，应用只能根据文字估算每个字何时唱出。估算方法用 160 首网易云歌曲实测校准（中文、日文、英文及少量韩文），这些歌曲同时有逐字 YRC：以其真实 LRC 行时间为输入，以 YRC 逐字起点为标准答案。

What the measurements showed, and how the estimate now works:

- Singers spread a line's syllables almost exactly evenly. The error was in each line's pace, not in the shape.
- A cue holds its sung units plus about two more: the held last vowel and the breath. So a line's own length, divided by its units plus two, sets its pace.
- That pace is capped at 1.2 times the song's pace, so an instrumental gap after a line cannot slow its words. The song's pace is the lower median, over every line of the document, of its cue length divided by its sung units plus two (without interior breaks), leaving out very sparse and very dense lines; documents longer than 256 lines are sampled evenly. Each pace is pulled a tenth of the way (in log terms) toward a typical 0.30 s per unit.
- A punctuation run, or a space between two Chinese or Japanese phrases of at least two syllables, is a phrase break worth two units. Text that spaces out every character is not.
- In Japanese lines (at least two kana), a kanji counts as 1.5 units.
- The last sung character still holds to the end of the cue. A last line with no end lasts its units plus the hold at the song's pace (0.30 s per unit without one), within 1.2–12 s.
- Silent marks take no time: the kana middle dot ・, emoji (even with a variation selector), brackets and quotes. Small kana (きゃ) are sung with the kana before them. Fullwidth Latin, Vietnamese, Greek and Cyrillic are weighed by word, not by letter.

实测结论与现在的估算方式：

- 歌手在一句之内几乎均匀地分配音节；误差主要来自每一句的语速，而不是句内的形状。
- 一句的时长约等于它的音节数再加两个单位（拖长的尾音与换气）。因此用本句时长除以（音节数 + 2）来决定本句语速。
- 语速不超过整首歌语速的 1.2 倍，句后的间奏不会拖慢前面的字。整首歌的语速取全文各句“时长 ÷（音节数 + 2）”（不计句内停顿）的下中位数，排除过于稀疏或过于密集的句子；超过 256 句的文档均匀抽样。每个语速再向典型的每单位 0.30 秒轻微收拢（对数意义上的十分之一）。
- 标点串，或两段各含至少两个音节的中日文短语之间的空格，算作一个两单位的换气停顿；每个字之间都加空格的写法不算。
- 日文句（至少两个假名）中，汉字按 1.5 个单位计算。
- 最后一个唱出的字仍承接到句末。没有结束时间的最后一句，按整首歌的语速（没有时用每单位 0.30 秒）计算其音节与尾音时长，限定在 1.2–12 秒。
- 不发音的符号不占时间：片假名中点 ・、表情符号（含变体选择符）、括号与引号。小写假名（きゃ）与前一个假名同时唱出。全角拉丁字母、越南文、希腊文与西里尔文按词计算，而不是按字母。

Results on 32 held-out songs not used for tuning (mean error of word onsets; lower is better): with the songs' real LRC lines 0.546 s → 0.471 s, words within 0.3 s 47% → 52%; with correct line starts 0.425 s → 0.340 s, within 0.3 s 58% → 66%. Lines whose last word lights more than 1 s early ("runs ahead, then waits") 10.4% → 9.0%, more than 1 s late ("falls behind") 11.0% → 7.8%. Five-fold cross-validation improved every fold. Remaining limits: lines whose LRC timestamp comes well before the vocal (no text rule can fix line-start sync), long lines with a long held last note, and Korean (Hangul) text, which the corpus barely covers. The constants follow NetEase's stamping convention; LRCLIB and Apple Music lines may differ slightly.

在 32 首未参与调参的歌曲上（逐字起点平均误差，越小越好）：使用真实 LRC 行时间时 0.546 秒 → 0.471 秒，0.3 秒内的字 47% → 52%；行起点准确时 0.425 秒 → 0.340 秒，0.3 秒内 58% → 66%。末字提前 1 秒以上（“先跑到前面再停住”）的句子 10.4% → 9.0%，落后 1 秒以上的句子 11.0% → 7.8%。五折交叉验证每一折都有改善。仍然存在的局限：LRC 时间戳明显早于人声的句子（行起点不同步无法靠文字修正）、尾音特别长的长句，以及语料中几乎没有的韩文（谚文）。常数依据网易云的打点习惯，LRCLIB 与 Apple Music 的行时间可能略有不同。

The reported QQ cue (the first chorus line of 齐秦's 《大约在冬季》) now places its final character at 25.44 s instead of 25.01 s, against 26.11 s for equal spreading; its cue end stays 26.54 s. On NetEase's word-timed copies of the same song, that final character is sung about 1.96 s into the line and held about a second, so both estimates are late for that particular line (with correct line starts, by 0.4–0.6 s before and 0.55–0.75 s now), while the song as a whole is estimated slightly better than before (mean error 0.264 s → 0.257 s across four recordings). Regression neighbours use placeholder text with the same character counts, not the song's lyrics.

用户报告的 QQ 音乐歌词（齐秦《大约在冬季》副歌第一句）末字估算由 25.01 秒变为 25.44 秒，平均分配时为 26.11 秒，句终点仍为 26.54 秒。在网易云同一首歌的逐字版本中，这个末字在本句开始约 1.96 秒后唱出并拖长约一秒，因此对这一句两种估算都偏晚（行起点准确时，之前晚 0.4–0.6 秒，现在晚 0.55–0.75 秒），而整首歌的估算略好于之前（四个录音版本的平均误差 0.264 秒 → 0.257 秒）。回归用例的邻句使用同字数的占位文本，不保存歌词。

Scrolling highlights, kinetic compositions, long-line reading layouts, echoes and local accents share the same context and schedule. The song's pace is cached once per document and recognised without a scan when the same lines are shown again; provider word onsets in up to eight neighbouring cues still take precedence when present. Real provider timestamps remain authoritative; only the internal timing of multi-character provider words is estimated, within their supplied boundaries. Latin-script text continues to appear by whole word. Seeks reconstruct the same schedule without retaining playback history. This remains a text estimate, not vocal recognition; it never shifts source line timestamps or writes word timestamps into the lyric document.

滚动高亮、动态字幕、长句阅读布局、回声与局部强调使用相同的语速与时序。整首歌的语速每个文档缓存一次，再次显示同一组歌词时无需重新扫描；邻近八句中若有提供方逐词起点，仍优先使用。提供方的真实时间保持原值，多字的提供方词语只在原始边界内估算内部时间。拉丁文字仍整词出现；拖动回放会重建相同时间表，不依赖播放历史。这仍是文本估算，不是人声识别；不会移动原始行时间，也不会向歌词文档写入逐字时间。
