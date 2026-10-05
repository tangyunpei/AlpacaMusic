# Apple Music 实时音频分析调查记录

记录日期：2026-10-02。状态：公开接口研究完成，系统采样尚未实现或实测。

## 当前情况

AlpacaMusic 通过 MusicKit 播放 Apple Music。MusicKit 的公开播放接口没有提供可供本应用分析的 PCM 采样输出。当前播放器因此返回不可用的分析数据；示波器与频谱显示静候画面，不用合成波形冒充真实音乐信号。其他可分析的本地音乐、音频链接及网易云/QQ 音乐使用已有音频分析通道。

这不是“Apple Music 波形永远无法实现”的结论。尚未验证的另一条路线是通过系统音频接口采集实际输出，再交给同一音频分析器。

## 可验证的后续路线

优先研究公开的 Core Audio process taps。本机 macOS 27 SDK 提供 AudioHardwareCreateProcessTap / AudioHardwareDestroyProcessTap（从 macOS 14.2 可用，未标记弃用）；CATapDescription 的 bundleIDs 和进程恢复配置从 macOS 26 可用，符合项目最低 macOS 26 的目标。

该路线需要独立的系统音频录制授权及 NSAudioCaptureUsageDescription。已有 Apple Music 授权不等于录音授权。应在用户明确启用此功能时申请，不应在启动、登录或导入曲库时自行采集。

需要依次验证：

1. 确定 MusicKit 播放时实际输出音频的进程，尽量只选择相关进程，不混入通知及其他应用。
2. 在用户授权后尝试不静音原始播放的 tap，检查实际采样是否非零、格式与采样率是否正确。
3. 验证订阅歌曲、下载歌曲、不同输出设备及耳机；受保护内容是否允许采集，必须以当前系统实测为准。
4. 验证暂停、换曲、拖动进度、设备切换、授权拒绝/撤销和采集失败的重置行为。
5. 成功后再接入 AudioAnalyzer，并验证波形/频谱与播放同步、延迟和资源使用。失败应说明原因，不使用虚构的实时信号。

ScreenCaptureKit 的应用级音频筛选也可作为比较路线。当前没有官方保证或本机实测证据证明上述路线一定可以采到 Apple Music 订阅音频，也没有证据支持“一定被保护机制阻断”。

## 官方参考

- [MusicPlayer](https://developer.apple.com/documentation/musickit/musicplayer)
- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- [ScreenCaptureKit 应用级音频筛选介绍](https://developer.apple.com/videos/play/wwdc2022/10155/)

本次三环示波器与竖条频谱升级仅扩展既有采样分析与显示，没有开启系统音频采集或请求新的权限。
