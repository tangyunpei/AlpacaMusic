# Lyric timing and ahead-of-playback analysis / 歌词时间与提前分析

[English](#english) · [简体中文](#简体中文)

## English

The source build selects timing in three layers:

1. **Measured platform timing.** NetEase YRC and QQ QRC are preferred when valid. Audio analysis never replaces their word timestamps. Invalid or unavailable word data falls back to LRC. See [platform details](platform-word-lyrics.md).
2. **On-device audio anchors.** For readable local files and the direct media URL already resolved by the player, the app uses macOS SpeechAnalyzer/SpeechTranscriber to measure recognized text ranges, matches them in order to the existing lyrics, and independently checks voice regions with SoundAnalysis's speech/singing/choir classes. It does not use frequency peaks as syllables. This is conservative recognition-assisted alignment, not phoneme forced alignment or vocal stem separation. Chinese ASR may return a multi-character group: its measured range is kept and internal character timing is still estimated. English and Spanish continue to appear word by word.
3. **Cadence fallback.** Unmatched or uncertain lines retain the [neighbor-cadence estimator](lyric-singing-timing.md). Instrumental intervals, hallucinated text without vocal evidence, low confidence, substituted words, incomplete matches, and excessive drift are rejected.

**Settings → Background audio lyric alignment** controls the second layer; it is enabled by default. The first use may download an Apple language model. Audio recognition and voice classification run locally, without microphone, system-audio capture, or server speech recognition. Model availability depends on the Mac and lyric language. Unsupported models or failed downloads leave existing timing usable and show a reason in Settings / the immersive lyric menu.

Analysis is a utility-priority background task and never delays playback. It processes up to 45-second audio windows, starting near the current playhead and then upcoming cues. A seek changes the next analysis priority. The audio is read ahead from the file or direct URL; recognition does not wait for playback taps. First playback can still use estimates while download/model preparation runs. Fresh results do not change an already displayed phrase halfway through; they apply to future cues and are available on later seeks/replays.

HTTP audio is temporarily downloaded using an ephemeral session, without copying platform cookies, then removed with generated PCM when the job finishes/cancels. Signed URLs remain ephemeral. Analysis is bounded to 64 MB / 20 minutes, with request/resource timeouts; HLS/live streams are excluded. Local file permissions are acquired independently for the job. Modified files invalidate in-progress work. Only a regular readable audio file is accepted; unsupported media falls back gracefully.

The derived cache stores word **character ranges and timestamps**, voice intervals, confidence/coverage metrics, and identity hashes. It does not store raw audio, recognized text, lyric plaintext, login credentials, or signed URLs. Identity includes full source/resource/title/artist/album/version metadata, the complete actual media SHA-256, lyric text/timing digest, local file fingerprint when relevant, and engine/algorithm versions. Live, remastered, original, cover, and changed recordings cannot share results merely because titles match. macOS major/minor is included in the engine key. LRCLIB itself may still supply the wrong recording; this cache does not prove that an external lyric match is correct.

Cache writes are atomic; each load validates original text ranges, cue bounds, confidence, independent vocal overlap, and platform precedence. It holds at most 64 records / 16 MB under `AlpacaMusic/lyric-alignments` in Application Support. A corrupt, excessive, or unsafe record becomes a cache miss. Account changes, song changes, lyric import/reload, and disabling analysis cancel the prior generation, so stale results cannot reach another song.

Apple Music and Spotify protected playback do not expose analyzable audio through this implementation, including for background alignment. Their line-only lyrics continue to use cadence estimates. Singing ASR can fail on polyphony, reverb, language mixing, or unusual delivery; no claim of universally accurate character-level synchronization is made. A known-lyrics phoneme model could improve this later. TIFA was researched but not bundled: its code is MIT while the released pretrained weights are CC BY-NC-SA 4.0.

Sources: [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber), [SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector), [Apple SoundAnalysis demonstration](https://developer.apple.com/videos/play/wwdc2021/10036/), [TIFA model release](https://github.com/openvpi/TIFA/releases/tag/v1.0.0), [TIFA ONNX deployment requirements](https://github.com/openvpi/TIFA/blob/main/ONNX.md).

## 简体中文

源码版本按三层选择时间：

1. **平台实测时间。** 网易云 YRC、QQ QRC 有效时优先使用，音频分析不会覆盖其逐字／逐词时间。数据损坏或不可用则回退 LRC。见[平台说明](platform-word-lyrics.md)。
2. **本机音频锚点。** 对可读取的本地文件，以及播放器已经解析出的直接音频地址，使用 macOS SpeechAnalyzer／SpeechTranscriber 测量识别文本的时间范围，再与已有歌词按顺序匹配；另用 SoundAnalysis 的语音／歌唱／合唱分类独立核对人声区间。不会把频谱峰值当成字音。这是保守的识别辅助对齐，尚不是音素强制对齐，也不是人声分轨。中文可能返回多个字组成的识别块：保留其实际测量范围，块内逐字仍为估算；英语、西语仍逐词显示。
3. **节奏估算回退。** 未匹配或不可靠的句子保留[相邻句节奏算法](lyric-singing-timing.md)。没有人声证据的幻觉文本、纯伴奏、低置信度、替换词、缺词和偏移过大的结果会被拒绝。

**设置 → 后台音频字幕对齐**控制第二层，默认开启。首次可能下载 Apple 语言模型；音频识别和人声分类均在本机运行，不使用麦克风、系统音频录制或服务器语音识别。模型可用性取决于设备和歌词语言；不支持或下载失败时保留已有时间，并在设置／沉浸歌词菜单说明原因。

分析以低优先级后台任务运行，不阻塞播放。每段最多 45 秒，优先分析当前位置附近和接下来的歌词，跳转后调整下一段优先级。提前读取文件或直接音频地址，不等待播放采样。第一次播放时，在音频读取或模型准备期间仍可能使用估算。新结果不会改写已显示的半句歌词，只应用于后续句子；重播／跳转可使用已缓存结果。

HTTP 音频通过临时网络会话读取，不复制平台 Cookie；任务完成／取消后删除临时音频及生成的 PCM。签名地址仅在内存中使用。限制为 64 MB／20 分钟，并设请求与资源超时；不分析 HLS／直播。本地文件权限由分析任务独立持有，分析期间文件修改会使结果失效。只接受可读取的普通音频文件，不支持的媒体正常回退。

派生缓存只保存字词在原文中的**字符范围与时间**、人声区间、置信度／覆盖指标和身份摘要，不保存原始音频、识别文本、歌词原文、登录凭据或签名地址。身份包含完整音源／资源／歌名／歌手／专辑／版本资料、实际完整媒体的 SHA-256、歌词原文与时间摘要、适用的本地文件指纹、模型和算法版本。原版、现场版、重制版、翻唱版和修改过的音频，不会因为同名复用结果；模型键还包含 macOS 主次版本。LRCLIB 本身仍可能匹配错录音版本，这份缓存不保证外部歌词匹配正确。

缓存原子写入，每次读取重新核对原文字词范围、句子边界、置信度、独立人声覆盖及平台优先级。Application Support 下 `AlpacaMusic/lyric-alignments` 最多保存 64 条／16 MB；损坏、过大或不安全的记录视为未命中。切换账号／歌曲、导入／重新读取歌词，以及关闭分析会取消上一代任务，旧结果不会进入其他歌曲。

当前 Apple Music、Spotify 受保护播放无法提供可分析音频，包括后台对齐；其只有整句时间的歌词继续估算。复音、混响、多语言或特殊唱法可能造成歌唱识别失败，不承诺所有歌曲逐字准确。未来可进一步接入已知歌词的音素对齐模型。已调研 TIFA，但没有打包其模型：代码 MIT，发布的预训练权重为 CC BY-NC-SA 4.0。

参考来源同英文部分。

## Verification, 2026-10-07 / 验证记录

- Platform parsing/transport subset: 102 tests passed, including 17 new YRC/QRC/envelope cases. These use independent protocol vectors and mock transports; no logged-in platform claim.
- Isolated PCM tests: 10 passed. Remaining suite: 706 discovered, 701 executed and passed; four native model cases were skipped there and run explicitly, and the optional one-minute GPU budget case was not rerun.
- Explicit native model QA: three cases passed for original English/Mandarin generated speech and instrument/silence rejection. The Mandarin fixture measured 11 character anchors; adding ten seconds of silence left every onset/end unchanged (last character 2.52–2.76 seconds). This is speech-fixture evidence, not a real-song accuracy rating.
- Complete ahead-read → native anchor → cache → second-read pipeline: one explicit original-speech case passed; second read restored exactly the stored times without another alignment pass. Cache content omitted lyric text/audio paths.
- Localization: 1,074 matching English/Simplified Chinese keys passed. Build scripts: 17 checks passed. SDK 27 API audit passed with warnings treated as errors; shipping deployment target remains 26.0. macOS 26 hardware runtime was not tested.

平台相关 102 项测试通过，新增 17 项 YRC／QRC／协议封装测试；使用独立向量与模拟传输，不等同于真实账号平台验收。音频采样独立 10 项通过；其余发现 706 项，其中 701 项执行通过，4 项本机模型测试另行显式通过，未重复运行一分钟 GPU 性能测试。本机原声 3 项加完整后台缓存链路 1 项均通过；中文原创读音追加 10 秒静音后 11 个字的时间保持不变，末字仍在 2.52–2.76 秒，不据此宣称真实歌唱准确率。英中 1,074 个键、17 项构建脚本检查及 SDK 27 弃用审核通过；仍最低 macOS 26.0，未在 macOS 26 实机运行。
