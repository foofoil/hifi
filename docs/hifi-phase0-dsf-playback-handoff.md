# Hi-Fi 阶段性交接：DSF / DoP 播放闭环

> 更新日期：2026-09-02  
> 当前里程碑：用户已在 foofoil 箔片内成功播放 Stereo DSD64 DSF，SMSL DAC 正确显示 `DSD64`，音乐正常且无明显杂音。  
> 用途：新会话中的 agent 应先读本文，再继续 `foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md` 的后续开发，避免重复 Phase 0 的 HAL / DoP 排查。

## 1. 当前结论

Hi-Fi 已形成一条可实际使用的最小播放闭环：

```text
DSF 文件
→ foofoil Provider Resolver
→ Hi-Fi in-process 插件
→ DSFRawStream（按 channel block 读取）
→ DSFDoPSource（LSB-first 归一化及 DoP 封装）
→ SPSCFloatRingBuffer
→ CoreAudio HAL IOProc
→ USB DoP DAC
```

当前确认可工作的范围：

- 容器：DSF；
- 编码：raw DSD；
- 声道：Stereo；
- 已实测采样率：DSD64 / 2.8224 MHz；
- 输出：DoP，经 CoreAudio HAL 独占 USB DAC；
- 宿主能力：打开文件、播放、暂停、进度轮询、拖动 Seek、结束后从头重播、输出设备选择；多个 DSF 可形成队列，通过 Navigator、上一项/下一项切换并自动续播；Hi-Fi 已接入宿主通用音频呈现层，复用封面/元数据加载、播放条、底部进度线、hover 显隐、空格键和系统媒体键；
- 生命周期：暂停、切换设备、关闭/替换箔片时停止 IO、恢复设备格式并释放 Hog Mode；
- 安全范围：插件会话存活期间持有文件 bookmark 对应的 security-scoped access。
- 稳定性：HAL 输出时间线会统一重写 DoP marker；即使发生奇数帧 underrun，静音后的音频也不会沿用 producer 的旧 marker 相位；
- 诊断：Runtime 的 `mediaPlayback.underrunCount` 会随状态轮询返回当前播放尝试的 underrun 次数。

尚未完成的能力不能被误认为已实现：

- DSD → PCM fallback；
- raw DFF 或 DST DFF 的实际播放；
- DSD128 / DSD256 的真实硬件回归；
- SACD 虚拟 Track 的宿主媒体项契约；
- SACD ISO；
- DSF 内嵌 metadata 的专项解析和正式 Session 恢复；宿主侧同目录封面与通用 metadata 加载已接入；
- Release 插件安装/升级体验；
- 独立 Engine Service/XPC 隔离。当前为了验证边界，播放引擎仍在 in-process 插件中。

## 2. 硬件验证记录

实测设备为 `SMSL USB AUDIO`。其 CoreAudio UID 在测试机器上是：

```text
AppleUSBAudioEngine:SMSL:SMSL USB AUDIO:141200:1
```

DSD64 DoP 使用 176.4 kHz PCM carrier，因为：

```text
2,822,400 DSD samples/s ÷ 16 DSD samples/DoP frame = 176,400 frames/s
```

已验证的工作格式组合：

- physical format：176400 Hz、Stereo、integer LPCM；设备可能暴露 24-bit aligned-high 或 32-bit packed；
- virtual format：176400 Hz、Stereo、Float32；
- physical 与 virtual 分开配置；
- Hog Mode 可取得，释放时必须重新读取实际 owner，不能只依赖首次写入结果；
- HAL callback 的 `AudioBufferList` 在该设备上是一个 active interleaved buffer、2 channels；
- 发送连续合法 DoP marker 后 DAC 会从 `176` 切换到 `DSD64`；停止后恢复原 physical/virtual format。

用户最终验收：箔片内播放真实 DSF，DAC 显示 DSD64，声音正常。

## 3. 不可回退的 DoP 数据约束

这里曾出现过“DAC 显示 DSD64，但输出巨大杂音”的错误。根因不是 HAL，而是一个 DoP frame 内两个 DSD 字节的时间顺序颠倒。

必须保持下面的转换：

1. DSF `bitsPerSample == 1` 表示每字节内 LSB-first；读取后逐字节 bit-reverse，归一化成 oldest bit at MSB。
2. DoP 的 16-bit payload 中，最早的 8 个 DSD sample 必须放在 payload 高字节，后 8 个放在低字节。
3. marker 位于 24-bit word 的最高字节，并逐 frame 在 `0x05` / `0xFA` 间交替；同一 frame 的左右声道 marker 相同。
4. 对 SMSL 的 32-bit packed physical format，24-bit DoP word 位于高 24 位，最低 8 位为零。
5. 经 Float32 virtual stream 传输时，整数映射必须可逆，不能经过音量、混音、SRC 或 DSP。

当前编码公式是：

```swift
word = (marker << 16) | (firstChronologicalByte << 8) | secondChronologicalByte
packed32 = word << 8
floatSample = Float32(Int32(bitPattern: packed32)) / 2_147_483_648
```

不要把公式改成 `first | (second << 8)`。marker 仍会被 DAC 识别，但 DSD noise shaping 会被破坏，听感是强烈杂音。

DoP silence 使用 payload `0x69, 0x69`，marker 仍须连续交替。任何 underrun 或音频/静音切换都不应破坏 marker phase。

## 4. 代码地图

### Hi-Fi 独立仓库

- `Package.swift`：Core、动态 Runtime、三个诊断 CLI 和测试目标。
- `ExtensionManifest.json`：Hi-Fi provider/capability 声明。
- `build-plugin`：构建 `.foofoilextension` bundle 并签名。
- `Sources/HiFiExtensionCore/DSDContainerParser.swift`：DSF/DFF descriptor parser。
- `Sources/HiFiExtensionCore/DSFRawStream.swift`：DSF channel-block 流读取、位序归一化、sample seek。
- `Sources/HiFiExtensionCore/DoPFrameEncoder.swift`：DoP marker、payload 时序、physical word 与 Float32 映射。
- `Sources/HiFiExtensionCore/DoPOutputTimeline.swift`：按 HAL 时间线统一 marker 并补 DoP silence。
- `Sources/HiFiExtensionCore/DSFDoPSource.swift`：DSFRawStream 到 interleaved Float32 DoP frame。
- `Sources/HiFiExtensionCore/SPSCFloatRingBuffer.swift`：实时线程使用的固定容量单生产者/单消费者 ring。
- `Sources/HiFiExtensionCore/CoreAudioDeviceCatalog.swift`：输出设备及 physical format 枚举。
- `Sources/HiFiExtensionCore/CoreAudioHALFormatProbe.swift`：DoP transport 规划、格式切换、Hog Mode 和诊断 silence。
- `Sources/HiFiExtensionCore/HALDSFPlaybackEngine.swift`：文件 worker、预缓冲、HAL IOProc、停止与恢复。
- `Sources/HiFiExtensionRuntime/Runtime.swift`：C ABI Runtime、播放会话仲裁、命令和设备菜单状态。
- `Sources/HiFiInspect/main.swift`：文件/设备/stream-check 诊断。
- `Sources/HiFiHALProbe/main.swift`：HAL dry-run、格式 apply/restore、DoP silence 验证。
- `Sources/HiFiRuntimeSmoke/main.swift`：Runtime ABI 与 Session JSON 冒烟测试。
- `Tests/HiFiExtensionCoreTests/DSDContainerParserTests.swift`：当前 16 项核心测试。

### foofoil 宿主改动

- `foofoil/ExtensionKit/InProcessContentProvider.swift`：把稳定 C ABI JSON 消息适配为 ContentProvider。
- `foofoil/ExtensionKit/MediaPlaybackContracts.swift`：播放、队列、设备选择的值类型契约和校验。
- `foofoil/ExtensionKit/ExtensionLoader.swift`：签名校验、动态库入口和 Runtime 调用。
- `foofoil/ExtensionKit/ExtensionHost.swift`：Debug bundle 加载、provider 路由、命令和 close 生命周期。
- `foofoil/ExtensionKit/ExtensionPresentationView.swift`：按 provider 路由通用扩展呈现或 Hi-Fi 音频呈现。
- `foofoil/ExtensionKit/ExtensionAudioModeView.swift`：把扩展播放快照/命令适配到宿主媒体控制协议，并接入空格键与系统媒体键。
- `foofoil/Views/AudioPresentationView.swift`：内置音频与 Hi-Fi 共用的封面、元数据、播放条和底部进度线。
- `foofoil/AppState/AppState+ContentOpen.swift`：DSF 路由至扩展、命令执行及 status 非持久化轮询。
- `foofoil/AppState/AppState.swift`：扩展会话 retain/release/close。
- `foofoil/App/AppDelegate+MenuSetup.swift`：Hi-Fi 输出设备层级菜单。
- `run`：Debug 构建后构建、注入、签名 Hi-Fi bundle，再启动 foofoil。

## 5. 实时线程约束

`HALDSFPlaybackEngine` 的 worker 负责文件 I/O、DSF block 拆分、bit reversal、DoP 编码和 ring 写入。HAL callback 只能：

- 从预分配 ring 读取；
- 写入已有 output buffer；
- underrun 时补合法 DoP silence；
- 更新 atomic 计数。

HAL callback 中禁止文件 I/O、锁、内存分配、JSON、日志或 Swift collection 扩容。当前 ring 容量为 131072 frame，预缓冲 32768 frame，worker chunk 为 4096 frame。

进程级只有一个 `HALDSFPlaybackEngine`。多个箔片会话可以存在，但同一时刻只能有一个会话持有独占设备；开始另一会话前会暂停并记录上一会话的位置。

## 6. 当前开发和验证命令

核心测试：

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/foofoil-hifi-swiftpm-cache \
CLANG_MODULE_CACHE_PATH=/tmp/foofoil-hifi-clang-cache \
swift test \
  --disable-sandbox \
  --scratch-path /tmp/foofoil-hifi-build
```

宿主相关测试：

```sh
xcodebuild test \
  -project foofoil.xcodeproj \
  -scheme foofoil \
  -destination 'platform=macOS' \
  -only-testing:foofoilTests/ExtensionKitTests
```

构建、注入插件并启动应用：

```sh
cd ../foofoil && ./run
```

检查真实 DSF 与设备：

```sh
swift run hifi-inspect --devices
swift run hifi-inspect --stream-check '/path/to/file.dsf'
```

注意：shell 中不要在单引号包围的文件路径内换行；换行会成为真实路径字符并导致 `NSCocoaErrorDomain Code=260`。

当前 Codex 执行沙箱可能看不到 CoreAudio output device，或在 `open foofoil.app` 时得到 LaunchServices `-10827`；这不代表用户桌面会话失败。真实设备和 GUI 验收应由用户终端执行 `./run`。用户环境已经完成过最终播放验收。

## 7. 已知欠账与风险

### 7.1 Manifest 已暂时收紧到 Runtime 实际范围

`ExtensionManifest.json` 当前只匹配 `dsf`，并声明已经接通的 seek、queue/navigator、设备选择和命令能力；Runtime 也会拒绝非 Stereo raw DSF 请求。DFF、ISO 与普通音频增强要在对应闭环实现后再逐项恢复声明。

不要提前恢复 capability：不能让 DFF/ISO 被选中后只在播放时才暴露 `unsupportedSource`，也不能报告 `isSeekable = true` 却没有带位置参数的 seek 命令。

### 7.2 音频列表由宿主统一持有

普通音频与 DSD 文件统一进入宿主 `FileListState(kind: .audio)`，使用同一个 `builtin.file-list` Navigator。拖入、追加、删除、拖拽重排、当前项动态图标、上一项/下一项、循环、随机和键盘操作均由 foofoil 实现一次；选中项目时宿主再通过 provider resolver 决定使用 AVFoundation 还是 Hi-Fi provider。Hi-Fi 的单曲会话只负责当前 DSD 项的解码、传输、seek 和设备状态，不拥有 UI 列表顺序。

扩展通过清单中的 `contentFamily: "audio"` 声明其格式应归入宿主音频呈现家族，宿主不硬编码 `.dsf`。Runtime 仍保留 `fileCollection`/queue 契约作为兼容及未来虚拟 Track 能力的基础，但 DSF 文件列表不再走这条路径。SACD Track 后续应通过正式的虚拟媒体项契约接入宿主队列，不生成临时 DSF，也不在插件中自绘第二套列表。

### 7.3 Underrun 与 marker continuity

当前有较大预缓冲，实测播放正常。音频 payload 和 silence 现已共享 HAL 输出时间线：callback 会保留 payload 并重写 marker，因此 ring starvation 后 source encoder 的旧相位不会造成重复 marker。已有确定性测试覆盖奇数帧 underrun 后恢复旧相位音频。

仍建议增加：

- 可注入慢 producer 的确定性测试；
- 设备断开、格式被外部应用改变、Hog Mode 被抢占的恢复测试。

### 7.4 错误与恢复仍较粗糙

UI 当前只显示本地化的通用“Hi-Fi 播放失败”。Runtime 内部保留了 failure description，但尚未形成结构化错误码。Session 状态持久化保存的是快照，应用重启后 Runtime 内部会话需要重新建立，不能直接复用旧 UUID 对应的内存记录。

### 7.5 DoP 固定音量

DoP 链路不能应用软件音量。Hi-Fi 已复用通用播放条，但通过 transport capability 隐藏软件音量控件；尚未实现硬件音量能力路由。后续实现时不得为了显示普通音频音量滑块而改写 DoP sample。

## 8. 建议的下一阶段顺序

建议先把“一个 DSF 正常播放”的结果加固，再扩大格式范围：

1. **播放稳定性**：共享 marker timeline、underrun 诊断、设备断开/占用错误、长时间播放和暂停恢复。
2. **统一音频列表（基础闭环已完成）**：普通音频与 DSF 共用宿主 `FileListState` 和 `builtin.file-list`；已有拖入/追加、删除、拖拽重排、上一项/下一项、循环/随机、自动续播、当前项同步及播放动态图标。后续补虚拟 SACD Track 的宿主媒体项契约。
3. **raw DFF 播放**：实现 DFF source 并复用现有 `DSDStream → DoP → HAL` 管线。
4. **PCM fallback**：内置扬声器、蓝牙和不支持目标 carrier 的设备必须可播放；再实现 Automatic / Prefer DoP / Always PCM 策略。
5. **metadata、封面、设置与 Session 恢复**：宿主通用封面/元数据呈现已复用；后续补 DSF 内嵌 metadata 专项解析、设置和恢复。
6. **DST 与 SACD ISO**：按主技术方案接入同一 queue/navigator，不生成临时 DSF。
7. **服务隔离和发布**：评估将 application-scope audio service 移至独立 Engine Service/XPC，并完成正式插件安装、升级与签名流程。

Phase 1 的真正验收不是“parser 能读 DFF”，而是：DSF/DFF 能从 Finder、拖放和批量列表进入同一宿主体验；DoP 不可用时自动 PCM；Seek、切歌、设备切换和恢复均不破坏音频设备状态。

## 9. 新会话启动清单

新 agent 开始工作时：

1. 在独立 `hifi` 仓库读取根目录 `AGENTS.md`、本文和 `foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md`。
2. 执行 `git status --short`；当前工作可能尚未提交，必须保留用户已有修改，不得 reset。
3. 运行 16 项 Hi-Fi 核心测试和相关 ExtensionKit 测试，建立基线。
4. 不要重新猜测 176.4 kHz 的来源，也不要重做已经通过的 DoP silence/Hog Mode spike。
5. 修改 DoP encoder、DSF bit order、physical/virtual format 或 callback layout 前，先阅读本文第 2、3、5 节并补回归测试。
6. 完成 app 代码变更后按仓库要求执行 `./run`，让用户直接进行硬件验收。

## 10. 关联文档

- 总体技术方案：`docs/foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md`
- 扩展系统方案：相邻 foofoil 仓库的 `foofoil/docs/foofoil_Extension_System_Implementation_Plan.md`
- 扩展部署记录：相邻 foofoil 仓库的 `foofoil/docs/phase0-extensionkit-deployment.md`
- DoP open Standard 1.1：<https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf>
- Sony DSF File Format Specification 1.01：<https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf>
