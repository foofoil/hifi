# Hi-Fi 阶段性交接：DSF / DoP 与统一音频体验

> 更新日期：2026-09-04
>
> 当前里程碑：Stereo DSD64 DSF/DFF 已在 SMSL DAC 上实机播放；DSD256 已通过真实硬件验证，DSD128 仍待回归。5.0 DFF 在立体声 DAC 上走 MLFT/MRGT 折混，设备提供 5/6/8 声道 DoP 格式时按 5.0/5.1/7.1 输出；因暂无环绕 DoP DAC，多声道输出实测暂缓。未压缩立体声 SACD ISO（3-in-14）已在同一 SMSL 上实机播放：CUE 式曲目列表、Seek、DoP 出声及自然续播均已确认。DAC 释放屏障与切歌播放意图已提交；设备断开/占用/Hog/睡眠恢复也已通过真实 DAC 手测。DST / SACD 多声道仍未做。
>
> 用途：新会话中的 agent 应先读本文，再读 `foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md`，保留三个仓库的现有改动并从第 9 节继续。

## 1. 仓库与模块边界

项目已经拆为三个兄弟仓库：

```text
foofoil/
├── foofoil/         # macOS 宿主、窗口、统一列表、音频 UI、Provider 路由
├── extension-kit/   # 独立 Swift Package；Manifest、Session、capability、C ABI
└── hifi/            # 独立 Hi-Fi 扩展；DSD parser、DoP、HAL、Runtime
```

边界必须保持：

- `foofoil` 拥有与格式无关的交互：封面、metadata 呈现、播放控件、外部文件列表、拖拽排序、当前项图标、键盘/系统媒体键、循环/随机、自动续播和窗口状态；
- `extension-kit` 只定义稳定、可序列化、跨仓库的通用契约；`ExtensionContentFamily.audio` 用来把扩展格式归入宿主音频家族；
- `hifi` 拥有高级格式解析、DSD 数据、DoP、HAL、设备探测和独占资源，不依赖宿主的 `FileListState`、SwiftUI View 或 `NSImage`；
- 外部 MP3/FLAC/DSF 等文件共享一个宿主 `FileListState(kind: .audio)`。选择当前项后才由 Provider Resolver 决定 Built-in Audio 或 `audio.hifi`；
- SACD ISO Track 没有独立 URL。第一版把同一 ISO 的曲目投影成宿主 `FileListState`（与 CUE 相同的专辑标题、曲目行、时长 badge、不可重排），插件 Session 持有 TOC/出流真相；不得生成临时 DSF 或自绘第二套列表。

## 2. 当前可工作的播放链路

```text
宿主 FileListState 当前项
→ Provider Resolver
→ audio.hifi 单文件 ContentSession
→ Hi-Fi in-process C ABI Runtime
→ DSFRawStream / DFFRawStream / SACDRawStream（DSF channel-block + LSB-first 归一化；DFF/SACD 交织 + MSB-first）
→ DSFDoPSource / DoPOutputTimeline
→ SPSCFloatRingBuffer
→ CoreAudio HAL IOProc
→ USB DoP DAC
```

当前确认范围：

- 容器：DSF、raw DFF，以及未压缩立体声 SACD ISO（DST 压缩 DFF/ISO 仍拒绝）；
- 编码：raw DSD；
- 声道：立体声已实测；5.0 DFF 按设备能力输出 5ch / 5.1（补静音 LFE）/ 7.1 或折成立体声对；
- 已实测：DSD64 / 2.8224 MHz 的 DSF 立体声与 DFF 立体声（SMSL），以及 DSD256 / 11.2896 MHz；5.0 DFF 在 SMSL 上为立体声折混；
- 输出：DoP，经 CoreAudio HAL 和 Hog Mode 输出到 USB DAC；
- 操作：播放、暂停、Seek、播完续播、单曲循环、顺序/顺序循环/随机、上一项/下一项和设备选择；
- 宿主一致性：普通音频与 DSD 可混合进入同一列表，支持追加、删除、拖拽重排、时长 badge、当前项动态图标、鼠标 hover、空格键、列表键盘操作和系统媒体键；
- 呈现：Built-in 与 Hi-Fi 共用 `AudioPresentationView`，复用同目录/内嵌封面加载、通用 metadata、播放条和底部进度线；右上技术信息已有浅色封面所需黑色阴影；
- 实时稳定性：HAL 输出时间线统一重写 DoP marker，奇数帧 underrun 后也不会沿用 producer 的旧 marker 相位；Runtime 状态回传 `underrunCount`；
- 安全范围：Hi-Fi Session 存活期间持有当前文件 bookmark 对应的 security-scoped access。

不要把下列能力误认为已完成：

- DSD → PCM fallback；
- DST DFF 或 SACD 多声道 / DST ISO 播放；
- DSD128 的真实硬件回归（DSD256 已通过）；
- 5.0/5.1/7.1 DoP 在环绕 DAC 上的真实硬件回归（代码已按格式探测选择，SMSL 上仍走立体声折混；因暂无相应设备暂缓）；
- DSF 内嵌 metadata 的专项 parser；当前主要复用宿主通用 metadata/封面能力；
- 完整的 Session 恢复；
- Release 插件安装/升级验收；
- 独立 Engine Service/XPC。当前 Runtime 是进程内动态插件，只是对象边界保持 C ABI/JSON 可迁移设计。

## 3. 统一列表的现行设计

这是已经确定的架构，不要退回旧方案：

```text
普通音频文件 ─┐
DSF 文件 ─────┼→ Host FileListState → builtin.file-list Navigator → 同一套 UI
DFF 文件 ─────┤                         │
SACD ISO ─────┘                         └→ activate 当前 URL / 容器曲目
                                            → Provider Resolver
                                            → Built-in 或 Hi-Fi
                                            （ISO 曲目复用同一 Session）
```

具体规则：

1. Hi-Fi manifest 通过 `contentFamily: "audio"` 声明 DSF/DFF 属于宿主音频家族，宿主不硬编码后缀；
2. 文件分类、混合追加、排序、删除、当前项与播放模式只存一份，归宿主所有；
3. Hi-Fi 对外部文件只建立当前项的 `singleFile` Session，不复制宿主列表；
4. `media.playback-queue` / `ui.navigator` 仍保留在扩展契约与 Runtime 中，作为旧 `fileCollection` 兼容和未来 SACD 虚拟 Track 的基础；
5. 列表上一项/下一项优先执行宿主 navigator；只有没有宿主列表时才回退扩展旧队列；
6. 播放结束先按宿主播放模式推进当前项，单曲循环才直接重播当前 Hi-Fi Session。

## 4. 已提交修复与硬件验证

### 4.1 DAC 释放屏障（已提交，手测通过）

`foofoil` `666e149`：宿主在启动新的原生/扩展播放器前等待 `hifi.close` 完成。用户已确认 DSD ↔ PCM、DSD → DSD、快速连点与暂停切换。

切歌播放/暂停意图：`foofoil` `4f5ae49`。暂停后切歌保持暂停，播放中切歌立即起播；自然播完仍自动续播。

### 4.2 设备恢复与结构化错误（真实 DAC 手测已通过）

以下场景已于 2026-09-04 使用真实 DAC 完成验收：

1. 播放中拔掉 USB DAC → 约 1 秒内显示「输出设备已断开」，DAC 不得留在 DSD64 / 176.4 kHz；
2. 播放中睡眠再唤醒 → 保持暂停，DAC 回到普通 PCM，点播放仍能进 DSD；
3. 选择被占用的设备或 Hog 失败 → 显示占用/独占失败，而不是底层 `String(describing:)`；
4. 起播失败（无效文件、不支持的 DoP 速率）→ 右上角为本地化错误，不是枚举 dump。

实现要点：非实时队列监听 `DeviceIsAlive`、设备列表、Hog owner 和 `willSleep`；断开时跳过对已消失设备的 format 写入；失败码经 `HiFiPlaybackError.localizationKey` 由宿主本地化。

### 4.3 raw DFF（立体声已手测；5.0 折混已手测）

- 立体声 DFF（`SLFT`/`SRGT`，DSD64 raw）已在 SMSL 上正常播放；
- 5.0 DFF（`MLFT`/`MRGT`/`C`/`LS`/`RS`）曾因只接受 2 声道而无法建 Session；现按设备 DoP 格式依次尝试 5ch → 6ch（ITU 5.1，LFE 静音）→ 8ch → 立体声 `MLFT`/`MRGT`；
- SMSL 无 5/6/8 声道 176.4 kHz 整数格式，5.0 文件走立体声折混；环绕 DAC 上的 5.0/5.1 输出尚未实机确认；
- 右上角状态会标明 `5ch · DoP`、`5.0→5.1 · DoP` 或 `5ch→Stereo · DoP`；
- DST 压缩 DFF 仍然不可播放。

### 4.4 未压缩立体声 SACD ISO（列表、Seek、出声、自然续播已手测）

实测盘：Gunter Wand / NDR《Beethoven Symphonies Nos.2 & 6》ISO（TWOCHTOC only，3-in-14，9 曲，约 3.1 GB）。输出仍是 SMSL USB AUDIO DSD64 DoP。

用户已确认：

1. 拖入 ISO 后宿主列表为 CUE 式：专辑标题、CUE 徽标、曲目标题、左侧序号、时长 badge，不可重排；
2. Seek 松手后定位正确，不中断播放；
3. 出声与同一套录音的 DSF 一致，不再是恒定高压线噪声或一截一截的音乐。

实现要点，不要退回去：

- 未压缩扇区的 `frame_info_count` 只计数，4 字节 DST 表仅 `dstEncoded` 时存在；
- 类型 2 包若以 `00 00 00` 开头且本扇区有 1…3 字节尾巴，这 3 字节是标记不是 DSD；尾巴仍是音频，必须接上。24 bit 全 0 按帧注入会听成恒定电流声；
- 同一扇区可能在凑满一帧后还有下一帧的开头。必须先吃完本扇区所有音频包和尾巴，再出帧；中途 return 会丢掉约 672 字节，听感不连续；
- 帧布局与 DFF 相同：逐字节 LRLR、MSB-first。不要按 16-bit 字交错拆；
- Seek：按约 14 扇区 / 3 帧落到附近 LSN，再靠 `frame_start` 对齐；`HALDSFPlaybackEngine.play` 在 Hog 之前 seek 流；
- 曲目文字块前常见 `02 00 00 00`（条目数，小端），然后才是 type + C 字符串；跳过该头才能读到 `Sinfonie Nr.2 …` 而不是退回 `Track 1`；
- SACD 自然播完由宿主列表切到下一曲。Runtime 在切项时若上一曲已到结尾，必须继续 `play`：播完时 `playingSessionID` 已清空，不能只看「当前是否在播」。暂停后再点下一曲仍保持暂停。此续播路径已通过连续两曲实听确认。

不要把下列情况当成已验收：DST ISO、SACD 多声道、普通 `.iso`。

## 5. 不可回退的 DoP 数据约束

这里曾出现“DAC 显示 DSD64，但输出巨大杂音”。根因是一个 DoP frame 内两个 DSD 字节的时间顺序颠倒。

必须保持：

1. DSF `bitsPerSample == 1` 为字节内 LSB-first；读取后逐字节 bit-reverse，使 oldest bit at MSB；
2. 16-bit DoP payload 中，最早 8 个 DSD sample 放高字节，后 8 个放低字节；
3. marker 在 24-bit word 的最高字节，逐 frame 以 `0x05` / `0xFA` 交替，同一 frame 左右声道 marker 相同；
4. SMSL 的 32-bit packed physical format 中，24-bit DoP word 位于高 24 位，最低 8 位为零；
5. Float32 virtual stream 映射必须可逆，不能经过音量、混音、SRC 或 DSP。

```swift
word = (marker << 16) | (firstChronologicalByte << 8) | secondChronologicalByte
packed32 = word << 8
floatSample = Float32(Int32(bitPattern: packed32)) / 2_147_483_648
```

不要改成 `first | (second << 8)`。DoP silence payload 为 `0x69, 0x69`，marker 仍须连续交替。

## 6. 硬件验证记录

实测设备：`SMSL USB AUDIO`。测试机器 UID：

```text
AppleUSBAudioEngine:SMSL:SMSL USB AUDIO:141200:1
```

DSD64 DoP carrier 为 176.4 kHz：

```text
2,822,400 DSD samples/s ÷ 16 DSD samples/DoP frame = 176,400 frames/s
```

已验证组合：

- physical：176400 Hz、Stereo、integer LPCM，兼容 24-bit aligned-high / 32-bit packed；
- virtual：176400 Hz、Stereo、Float32；
- physical 与 virtual 分开配置；
- HAL callback 在该设备上使用一个 active interleaved buffer、2 channels；
- 连续合法 marker 会使 DAC 从 `176` 切到 `DSD64`；停止会恢复原 physical/virtual format；
- Hog Mode 释放时必须重新读取实际 owner，不能只依赖最初写入值。

DFF 补充：

- 立体声 raw DFF DSD64 已在同一 SMSL 上播放；
- 5.0 raw DFF 在该设备上折成 `MLFT`/`MRGT` 立体声 DoP；不要把「能出声」当成 5.0 环绕已验收。

SACD ISO 补充：

- 未压缩立体声 3-in-14 ISO 已在同一 SMSL 上播放；Seek 与列表已确认；
- SACD 曲目自然结束后自动续播下一曲已通过连续两曲实听；
- 不要把 DST 或多声道 ISO 当成同一验收。

采样率补充：

- DSD256 已通过真实硬件播放验证；
- DSD128 尚未完成真实硬件回归，不要据此推定为已验收。

## 7. 代码地图

### `hifi`

- `ExtensionManifest.json`：匹配 `dsf` / `dff`，对 `iso` 使用 sniff；声明 `enhancementDomain`、`contentFamily: audio` 和已接通 capability；DST DFF/ISO 仍拒绝播放；
- `build-plugin`：构建、组装并签名 `.foofoilextension`；
- `Sources/HiFiExtensionCore/DSDContainerParser.swift`：DSF/DFF descriptor parser；ISO 走 `SACDISOParser`，不映射整盘；
- `Sources/HiFiExtensionCore/SACDISOParser.swift`、`SACDAudioSector.swift`、`SACDRawStream.swift`：Scarlet Book TOC、扇区拆包、未压缩立体声曲目流；
- `Sources/HiFiExtensionCore/DSFRawStream.swift`、`DFFRawStream.swift`：DSF channel-block / DFF 交织读取；DFF 可按 `outputMap` 输出原声道、5.1/7.1 补静音或立体声对；
- `Sources/HiFiExtensionCore/DoPFrameEncoder.swift`、`DoPOutputTimeline.swift`、`DSFDoPSource.swift`：DoP 数据与连续输出时间线；
- `Sources/HiFiExtensionCore/HiFiPlaybackError.swift`、`DeviceLifecycleWatch.swift`：结构化错误与拔出/占用/睡眠监听；
- `Sources/HiFiExtensionCore/SPSCFloatRingBuffer.swift`：实时线程固定容量 ring；
- `Sources/HiFiExtensionCore/CoreAudioDeviceCatalog.swift`、`CoreAudioHALFormatProbe.swift`：设备、格式、Hog Mode 和诊断；`plan` 按精确声道数匹配 DoP carrier；
- `Sources/HiFiExtensionCore/HALDSFPlaybackEngine.swift`：worker、预缓冲、IOProc、停止和设备恢复；按 `playbackOutputMaps()` 选择输出布局；
- `Sources/HiFiExtensionRuntime/Runtime.swift`：C ABI Runtime、进程级播放器仲裁、命令与设备状态；
- `Sources/HiFiInspect`、`HiFiHALProbe`、`HiFiRuntimeSmoke`：诊断 CLI；
- `Tests/HiFiExtensionCoreTests`：核心测试（含错误码与 DFF 流）。

### `extension-kit`

- `Sources/FoofoilExtensionKit/ExtensionModels.swift`：`ExtensionContentFamily` 与 provider manifest；
- `Sources/FoofoilExtensionKit/MediaPlaybackContracts.swift`：播放、queue、设备选择值类型及校验；
- `Sources/FoofoilExtensionABI`：稳定 C ABI header。

### `foofoil`

- `foofoil/FileList.swift`、`AppState/AppState+FileList.swift`：统一外部音频列表、CUE/SACD 曲目投影、拖拽排序、导航和播放模式；
- `foofoil/ExtensionKit/ExtensionHost.swift`：provider 路由、Debug runtime 装载及可等待 close；
- `foofoil/ExtensionKit/InProcessContentProvider.swift`：C ABI JSON 到内部 Provider 的适配；
- `foofoil/ExtensionKit/ExtensionAudioModeView.swift`：扩展状态到宿主媒体控制协议的适配；
- `foofoil/Views/AudioPresentationView.swift`：Built-in / Hi-Fi 共用封面、metadata 和控件；
- `foofoil/AppState/AppState+ContentOpen.swift`：异步 provider 路由、原生媒体切换与状态命令；
- `foofoil/AppState/AppState.swift`：Session retain/release 及 close 屏障；
- `foofoil/App/AppDelegate+Actions.swift`：打开面板包含扩展音频类型；
- `run`：构建宿主、构建并注入兄弟仓库 Hi-Fi Debug bundle、重签并启动。

## 8. 实时线程约束

文件 worker 负责文件 I/O、DSF block 拆分、DFF 交织拆分、SACD 扇区组装、bit reversal、声道映射、DoP 编码和 ring 写入。HAL callback 只能读取预分配 ring、写现有 output buffer、补合法 DoP silence 和更新 atomic 计数。Ring 的 `channelCount` 随当前 physical format 变化，不再写死为 2。

HAL callback 禁止文件 I/O、锁、内存分配、JSON、日志或 Swift collection 扩容。当前 ring 容量 131072 frame，预缓冲 32768 frame，worker chunk 4096 frame。

进程级只有一个 `HALDSFPlaybackEngine`。多个窗口 Session 可以存在，但同一时刻只有一个持有独占设备；开始另一播放前必须完成旧 Session 的停止与资源恢复。

## 9. 当前状态与下一步

截至本文更新时：

- `hifi` `9b09bce`：raw DFF、5.0 输出布局、设备恢复、未压缩立体声 SACD ISO 出流；
- `extension-kit` `1c3c923`：`MediaPlaybackQueueSnapshot.title` 供容器专辑标题使用；旧 queue JSON 仍可解码；
- `foofoil` 已提交 DAC 释放屏障 `666e149`、切歌播放意图 `4f5ae49` 与 seek-on-release `0f77844`；ISO sniff、CUE 式曲目列表（曲名 + 左侧序号）与 Session 复用见 `9782820`；
- 第 4.1 节切换手测、第 4.2 节设备恢复手测均已通过；第 4.3 节立体声 DFF 与 5.0 折混已通过；第 4.4 节 SACD ISO 列表/Seek/出声及自然续播已通过；
- DSD256 已通过真实硬件验证，DSD128 仍待回归；环绕 5.0/5.1/7.1 DoP 因暂无相应 DAC 暂缓；
- 核心测试以 `swift test` 为准；本地 ISO 存在时 `SACDISOParserTests` 会对照同专辑 DSF 前 16384 字节。

建议下一步顺序：

1. 实现 DSD → PCM fallback 以及 Automatic / Prefer DoP / Always PCM；
2. 用真实设备回归 DSD128；环绕 5.0/5.1/7.1 DoP 等具备相应 DAC 后再做；
3. 补 DSF/DFF 专项 metadata、设置和真正可恢复 Session；
4. DST 与 SACD 多声道；
5. 最后评估 Engine Service/XPC 和正式 Release 安装、升级、签名流程。

Phase 1 的验收不是 parser 能读 DFF，而是 DSF/DFF 能从 Finder、拖放和混合列表进入同一宿主体验；DoP 不可用时自动 PCM；Seek、切歌、设备切换和恢复不会遗留设备状态。

## 10. 新会话启动清单

1. 分别读取 `hifi/AGENTS.md`、本文和总技术方案；如修改其它仓库，再读对应 `AGENTS.md`；
2. 在 `hifi`、`foofoil`、`extension-kit` 分别执行 `git status --short`，保留全部现有修改；
3. 先运行 Hi-Fi 核心测试、ExtensionKit 测试和 `foofoil/run` 建立基线；
4. 第 4.2 节设备恢复手测已经通过；修改 encoder、bit order 或 Hog 释放顺序时仍须补回归测试；
5. 不要重新猜测 176.4 kHz 来源，也不要重做已通过的 DoP silence/Hog Mode spike；
6. 修改 encoder、DSF bit order、physical/virtual format 或 callback layout 前，先阅读第 5、6、8 节并补回归测试；
7. 不要把外部 DSF 列表重新塞回 Hi-Fi `fileCollection` queue；
8. 应用代码变更后执行 `cd foofoil && ./run`，真实设备与 GUI 最终由用户验收。

## 11. 常用命令

```sh
# Hi-Fi 核心测试
cd hifi
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/foofoil-hifi-swiftpm-cache \
CLANG_MODULE_CACHE_PATH=/tmp/foofoil-hifi-clang-cache \
swift test --disable-sandbox --scratch-path /tmp/foofoil-hifi-build

# ExtensionKit 测试
cd ../extension-kit
swift test --disable-sandbox --scratch-path /tmp/foofoil-extension-kit-build

# 构建、注入插件并启动宿主
cd ../foofoil
./run

# 用户终端中的文件/设备诊断
cd ../hifi
swift run hifi-inspect --devices
swift run hifi-inspect --stream-check '/path/to/file.dsf'
swift run hifi-inspect --stream-check '/path/to/file.dff'
swift run hifi-inspect --stream-check '/path/to/disc.iso'
```

Codex 受限沙箱可能无法访问 CoreAudio device、CoreSimulator 或用户 SwiftPM cache。真实硬件和 GUI 结论以用户桌面会话执行结果为准。

## 12. 关联文档

- 总体技术方案：`docs/foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md`
- 宿主扩展系统方案：`../../foofoil/foofoil/docs/foofoil_Extension_System_Implementation_Plan.md`
- 扩展部署记录：`../../foofoil/foofoil/docs/phase0-extensionkit-deployment.md`
- DoP open Standard 1.1：<https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf>
- Sony DSF File Format Specification 1.01：<https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf>
