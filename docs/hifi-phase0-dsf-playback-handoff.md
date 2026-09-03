# Hi-Fi 阶段性交接：DSF / DoP 与统一音频体验

> 更新日期：2026-09-03
>
> 当前里程碑：Stereo DSD64 DSF 已在 foofoil 内通过 SMSL DAC 实机播放；普通音频与 DSD 已统一使用宿主列表和音频 UI。最新的“切换解码器前等待 DAC 释放”修复已构建通过，仍待用户用真实 DAC 手工确认。
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
- SACD ISO Track 没有独立 URL。以后应增加版本化虚拟媒体项 contract，由插件维护 Track 真相、宿主复用 Navigator UI；不得生成临时 DSF 或自绘第二套列表。

## 2. 当前可工作的播放链路

```text
宿主 FileListState 当前项
→ Provider Resolver
→ audio.hifi 单文件 ContentSession
→ Hi-Fi in-process C ABI Runtime
→ DSFRawStream（channel block 读取、LSB-first 归一化）
→ DSFDoPSource / DoPOutputTimeline
→ SPSCFloatRingBuffer
→ CoreAudio HAL IOProc
→ USB DoP DAC
```

当前确认范围：

- 容器：DSF；
- 编码：raw DSD；
- 声道：Stereo；
- 已实测：DSD64 / 2.8224 MHz；
- 输出：DoP，经 CoreAudio HAL 和 Hog Mode 输出到 USB DAC；
- 操作：播放、暂停、Seek、播完续播、单曲循环、顺序/顺序循环/随机、上一项/下一项和设备选择；
- 宿主一致性：普通音频与 DSD 可混合进入同一列表，支持追加、删除、拖拽重排、时长 badge、当前项动态图标、鼠标 hover、空格键、列表键盘操作和系统媒体键；
- 呈现：Built-in 与 Hi-Fi 共用 `AudioPresentationView`，复用同目录/内嵌封面加载、通用 metadata、播放条和底部进度线；右上技术信息已有浅色封面所需黑色阴影；
- 实时稳定性：HAL 输出时间线统一重写 DoP marker，奇数帧 underrun 后也不会沿用 producer 的旧 marker 相位；Runtime 状态回传 `underrunCount`；
- 安全范围：Hi-Fi Session 存活期间持有当前文件 bookmark 对应的 security-scoped access。

不要把下列能力误认为已完成：

- DSD → PCM fallback；
- raw DFF、DST DFF 或 SACD ISO 播放；
- DSD128 / DSD256 的真实硬件回归；
- DSF 内嵌 metadata 的专项 parser；当前主要复用宿主通用 metadata/封面能力；
- 完整的 Session 恢复和结构化错误码；
- Release 插件安装/升级验收；
- 独立 Engine Service/XPC。当前 Runtime 是进程内动态插件，只是对象边界保持 C ABI/JSON 可迁移设计。

## 3. 统一列表的现行设计

这是已经确定的架构，不要退回旧方案：

```text
普通音频文件 ─┐
DSF 文件 ─────┼→ Host FileListState → builtin.file-list Navigator → 同一套 UI
未来 DFF 文件 ─┘                         │
                                        └→ activate 当前 URL
                                            → Provider Resolver
                                            → Built-in 或 Hi-Fi
```

具体规则：

1. Hi-Fi manifest 通过 `contentFamily: "audio"` 声明 DSF 属于宿主音频家族，宿主不硬编码 `.dsf`；
2. 文件分类、混合追加、排序、删除、当前项与播放模式只存一份，归宿主所有；
3. Hi-Fi 对外部文件只建立当前项的 `singleFile` Session，不复制宿主列表；
4. `media.playback-queue` / `ui.navigator` 仍保留在扩展契约与 Runtime 中，作为旧 `fileCollection` 兼容和未来 SACD 虚拟 Track 的基础；
5. 列表上一项/下一项优先执行宿主 navigator；只有没有宿主列表时才回退扩展旧队列；
6. 播放结束先按宿主播放模式推进当前项，单曲循环才直接重播当前 Hi-Fi Session。

## 4. 最新未提交修复：DAC 释放屏障

用户发现从正在播放的 DSD 切换到普通音频时，普通音频不能立刻成功播放。根因是旧实现将 `hifi.close` 放进 fire-and-forget `Task`，AVFoundation 播放器在 HAL stop、设备格式恢复和 Hog Mode 释放完成前就开始抢占设备。

当前修复位于 `foofoil` 工作树，尚未提交：

- `ExtensionHost.closeSessionAndWait` 提供可等待的关闭操作；
- `AppState.extensionSessionCloseTask` 串行关闭旧 Session，并在真正关闭后 release 扩展引用；
- DSD → 普通音频时，宿主保持 loading，等待关闭屏障完成后才设置原生媒体 URL；
- DSD → DSD 或其它扩展项目也等待旧屏障，避免新旧 Runtime 命令并发争用 HAL；
- `currentMediaRouteGeneration` 和当前列表 ID 会丢弃快速连续切换产生的过期结果；
- 新增延迟 close 回归测试，验证屏障不会提前完成。

需要优先手测：

1. 正在播放 DSD 时点击同一列表内 MP3/FLAC，普通音频应一次自动起播；
2. DSD → DSD 快速切换；
3. DSD → MP3 → DSD 连续快速点击，最终只播放最后选中项；
4. 切换后确认 DAC 回到普通 PCM 状态，且后续 DSD 仍能重新进入 DSD64；
5. 暂停状态下重复以上切换。

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

## 7. 代码地图

### `hifi`

- `ExtensionManifest.json`：当前只匹配 `dsf`，声明 `enhancementDomain`、`contentFamily: audio` 和已接通 capability；
- `build-plugin`：构建、组装并签名 `.foofoilextension`；
- `Sources/HiFiExtensionCore/DSDContainerParser.swift`：DSF/DFF descriptor parser；
- `Sources/HiFiExtensionCore/DSFRawStream.swift`：DSF 流读取、位序归一化和 sample seek；
- `Sources/HiFiExtensionCore/DoPFrameEncoder.swift`、`DoPOutputTimeline.swift`、`DSFDoPSource.swift`：DoP 数据与连续输出时间线；
- `Sources/HiFiExtensionCore/SPSCFloatRingBuffer.swift`：实时线程固定容量 ring；
- `Sources/HiFiExtensionCore/CoreAudioDeviceCatalog.swift`、`CoreAudioHALFormatProbe.swift`：设备、格式、Hog Mode 和诊断；
- `Sources/HiFiExtensionCore/HALDSFPlaybackEngine.swift`：worker、预缓冲、IOProc、停止和设备恢复；
- `Sources/HiFiExtensionRuntime/Runtime.swift`：C ABI Runtime、进程级播放器仲裁、命令与设备状态；
- `Sources/HiFiInspect`、`HiFiHALProbe`、`HiFiRuntimeSmoke`：诊断 CLI；
- `Tests/HiFiExtensionCoreTests`：当前 16 项核心测试。

### `extension-kit`

- `Sources/FoofoilExtensionKit/ExtensionModels.swift`：`ExtensionContentFamily` 与 provider manifest；
- `Sources/FoofoilExtensionKit/MediaPlaybackContracts.swift`：播放、queue、设备选择值类型及校验；
- `Sources/FoofoilExtensionABI`：稳定 C ABI header。

### `foofoil`

- `foofoil/FileList.swift`、`AppState/AppState+FileList.swift`：统一外部音频列表、拖拽排序、导航和播放模式；
- `foofoil/ExtensionKit/ExtensionHost.swift`：provider 路由、Debug runtime 装载及可等待 close；
- `foofoil/ExtensionKit/InProcessContentProvider.swift`：C ABI JSON 到内部 Provider 的适配；
- `foofoil/ExtensionKit/ExtensionAudioModeView.swift`：扩展状态到宿主媒体控制协议的适配；
- `foofoil/Views/AudioPresentationView.swift`：Built-in / Hi-Fi 共用封面、metadata 和控件；
- `foofoil/AppState/AppState+ContentOpen.swift`：异步 provider 路由、原生媒体切换与状态命令；
- `foofoil/AppState/AppState.swift`：Session retain/release 及 close 屏障；
- `foofoil/App/AppDelegate+Actions.swift`：打开面板包含扩展音频类型；
- `run`：构建宿主、构建并注入兄弟仓库 Hi-Fi Debug bundle、重签并启动。

## 8. 实时线程约束

文件 worker 负责文件 I/O、DSF block 拆分、bit reversal、DoP 编码和 ring 写入。HAL callback 只能读取预分配 ring、写现有 output buffer、补合法 DoP silence 和更新 atomic 计数。

HAL callback 禁止文件 I/O、锁、内存分配、JSON、日志或 Swift collection 扩容。当前 ring 容量 131072 frame，预缓冲 32768 frame，worker chunk 4096 frame。

进程级只有一个 `HALDSFPlaybackEngine`。多个窗口 Session 可以存在，但同一时刻只有一个持有独占设备；开始另一播放前必须完成旧 Session 的停止与资源恢复。

## 9. 当前状态与下一步

截至本文更新时：

- `hifi` 基线提交：`282da8c feat: declare audio content family for unified host list`；本文与总技术方案有未提交文档修改；
- `extension-kit` 基线提交：`356ae55 feat: add contentFamily to provider declaration`，工作树应为空；
- `foofoil` 基线提交：`bb1bba6 feat: unify audio list hosting with extension routing`；DAC 释放屏障和测试仍在工作树，不能 reset；
- `./run` 已在最新生产代码上完整成功：宿主 build、Hi-Fi Runtime build、bundle 注入与签名均通过；
- 最近已验证 `hifi` 16/16 核心测试、`extension-kit` 7/7 测试；
- 新增宿主回归测试尚未在当前 Codex 沙箱运行成功：`xcodebuild test` 在源码编译前被 `~/Library/Caches/org.swift.swiftpm` 和 CoreSimulator 权限阻断，不代表测试失败。

建议下一步顺序：

1. 让用户完成第 4 节真实 DAC 切换手测；通过后提交 `foofoil` 的释放屏障修复，并提交两份文档；
2. 补设备断开/占用、Hog Mode 失败、长时播放和暂停恢复测试，形成结构化错误；
3. 用真实设备回归 DSD128 / DSD256；
4. 实现 raw DFF source，复用现有 `DSDStream → DoP → HAL` 管线；
5. 实现 DSD → PCM fallback 以及 Automatic / Prefer DoP / Always PCM；
6. 补 DSF/DFF 专项 metadata、设置和真正可恢复 Session；
7. DST 与 SACD ISO；ISO 开工前先完成虚拟媒体项 contract；
8. 最后评估 Engine Service/XPC 和正式 Release 安装、升级、签名流程。

Phase 1 的验收不是 parser 能读 DFF，而是 DSF/DFF 能从 Finder、拖放和混合列表进入同一宿主体验；DoP 不可用时自动 PCM；Seek、切歌、设备切换和恢复不会遗留设备状态。

## 10. 新会话启动清单

1. 分别读取 `hifi/AGENTS.md`、本文和总技术方案；如修改其它仓库，再读对应 `AGENTS.md`；
2. 在 `hifi`、`foofoil`、`extension-kit` 分别执行 `git status --short`，保留全部现有修改；
3. 先运行 Hi-Fi 16 项测试、ExtensionKit 7 项测试和 `foofoil/run` 建立基线；
4. 优先确认第 4 节 DAC 释放修复，不要直接开始 DFF；
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
```

Codex 受限沙箱可能无法访问 CoreAudio device、CoreSimulator 或用户 SwiftPM cache。真实硬件和 GUI 结论以用户桌面会话执行结果为准。

## 12. 关联文档

- 总体技术方案：`docs/foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md`
- 宿主扩展系统方案：`../../foofoil/foofoil/docs/foofoil_Extension_System_Implementation_Plan.md`
- 扩展部署记录：`../../foofoil/foofoil/docs/phase0-extensionkit-deployment.md`
- DoP open Standard 1.1：<https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf>
- Sony DSF File Format Specification 1.01：<https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf>
