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
- 宿主能力：打开文件、播放、暂停、进度轮询、结束后从头重播、输出设备选择；
- 生命周期：暂停、切换设备、关闭/替换箔片时停止 IO、恢复设备格式并释放 Hog Mode；
- 安全范围：插件会话存活期间持有文件 bookmark 对应的 security-scoped access。

尚未完成的能力不能被误认为已实现：

- DSD → PCM fallback；
- raw DFF 或 DST DFF 的实际播放；
- DSD128 / DSD256 的真实硬件回归；
- Seek UI/命令（底层 source 和 engine 已能从对齐 sample 启动）；
- 多文件播放队列与现有列表/Navigator 的闭环；
- SACD ISO；
- metadata、封面和正式 Session 恢复；
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

### Hi-Fi Swift Package

- `HiFiExtension/Package.swift`：Core、动态 Runtime、三个诊断 CLI 和测试目标。
- `HiFiExtension/ExtensionManifest.json`：Hi-Fi provider/capability 声明。
- `HiFiExtension/build-plugin`：构建 `.foofoilextension` bundle 并签名。
- `HiFiExtension/Sources/HiFiExtensionCore/DSDContainerParser.swift`：DSF/DFF descriptor parser。
- `HiFiExtension/Sources/HiFiExtensionCore/DSFRawStream.swift`：DSF channel-block 流读取、位序归一化、sample seek。
- `HiFiExtension/Sources/HiFiExtensionCore/DoPFrameEncoder.swift`：DoP marker、payload 时序、physical word 与 Float32 映射。
- `HiFiExtension/Sources/HiFiExtensionCore/DSFDoPSource.swift`：DSFRawStream 到 interleaved Float32 DoP frame。
- `HiFiExtension/Sources/HiFiExtensionCore/SPSCFloatRingBuffer.swift`：实时线程使用的固定容量单生产者/单消费者 ring。
- `HiFiExtension/Sources/HiFiExtensionCore/CoreAudioDeviceCatalog.swift`：输出设备及 physical format 枚举。
- `HiFiExtension/Sources/HiFiExtensionCore/CoreAudioHALFormatProbe.swift`：DoP transport 规划、格式切换、Hog Mode 和诊断 silence。
- `HiFiExtension/Sources/HiFiExtensionCore/HALDSFPlaybackEngine.swift`：文件 worker、预缓冲、HAL IOProc、停止与恢复。
- `HiFiExtension/Sources/HiFiExtensionRuntime/Runtime.swift`：C ABI Runtime、播放会话仲裁、命令和设备菜单状态。
- `HiFiExtension/Sources/HiFiInspect/main.swift`：文件/设备/stream-check 诊断。
- `HiFiExtension/Sources/HiFiHALProbe/main.swift`：HAL dry-run、格式 apply/restore、DoP silence 验证。
- `HiFiExtension/Sources/HiFiRuntimeSmoke/main.swift`：Runtime ABI 与 Session JSON 冒烟测试。
- `HiFiExtension/Tests/HiFiExtensionCoreTests/DSDContainerParserTests.swift`：当前 15 项核心测试。

### foofoil 宿主改动

- `foofoil/ExtensionKit/InProcessContentProvider.swift`：把稳定 C ABI JSON 消息适配为 ContentProvider。
- `foofoil/ExtensionKit/MediaPlaybackContracts.swift`：播放、队列、设备选择的值类型契约和校验。
- `foofoil/ExtensionKit/ExtensionLoader.swift`：签名校验、动态库入口和 Runtime 调用。
- `foofoil/ExtensionKit/ExtensionHost.swift`：Debug bundle 加载、provider 路由、命令和 close 生命周期。
- `foofoil/ExtensionKit/ExtensionPresentationView.swift`：箔片内播放/暂停、进度、设备状态和错误提示。
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
  --package-path HiFiExtension \
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
./run
```

检查真实 DSF 与设备：

```sh
swift run --package-path HiFiExtension hifi-inspect --devices
swift run --package-path HiFiExtension hifi-inspect --stream-check '/path/to/file.dsf'
```

注意：shell 中不要在单引号包围的文件路径内换行；换行会成为真实路径字符并导致 `NSCocoaErrorDomain Code=260`。

当前 Codex 执行沙箱可能看不到 CoreAudio output device，或在 `open foofoil.app` 时得到 LaunchServices `-10827`；这不代表用户桌面会话失败。真实设备和 GUI 验收应由用户终端执行 `./run`。用户环境已经完成过最终播放验收。

## 7. 已知欠账与风险

### 7.1 Manifest 暂时超前于 Runtime

`ExtensionManifest.json` 当前声明了 `dsf`、`dff`、`iso`、`public.audio` 以及 queue/navigator/seekable 等能力，但 Runtime 目前只有 DSF DoP 播放闭环。下一位 agent 应尽早选择一种方式：

- 暂时收紧 manifest，只公开确实可用的范围；或
- 按 Phase 1 顺序补齐 DFF、queue/navigator、seek 和 fallback。

不能让 DFF/ISO 被选中后只在播放时才暴露 `unsupportedSource`，也不能长期报告 `isSeekable = true` 却没有 seek 命令。

### 7.2 列表尚未真正接通

单个 DSF 会通过强扩展名匹配进入 Hi-Fi，但 DSF 还没有映射成 foofoil 现有音频列表的 item/queue contribution。批量打开、同目录加入列表、上一项/下一项和 Navigator 选择尚未闭环。

实现时应使用现有 `PlaybackQueueSnapshot` 与 `NavigatorContribution`，不要在插件中自绘列表，也不要把 SACD Track 伪装成临时外部文件。

### 7.3 Underrun 与 marker continuity

当前有较大预缓冲，实测播放正常，但 underrun 路径仍需专项压力测试。音频 payload 和 silence 的 marker phase 必须共享同一输出时间线；若 ring starvation 后 source encoder 的 phase 与 HAL timeline 相反，DAC 可能短暂丢锁或产生爆音。

建议增加：

- 可注入慢 producer 的确定性测试；
- marker phase 连续性断言；
- runtime status 中的 underrunCount 诊断展示或日志；
- 设备断开、格式被外部应用改变、Hog Mode 被抢占的恢复测试。

### 7.4 错误与恢复仍较粗糙

UI 当前只显示本地化的通用“Hi-Fi 播放失败”。Runtime 内部保留了 failure description，但尚未形成结构化错误码。Session 状态持久化保存的是快照，应用重启后 Runtime 内部会话需要重新建立，不能直接复用旧 UUID 对应的内存记录。

### 7.5 DoP 固定音量

DoP 链路不能应用软件音量。当前没有为 Hi-Fi 单独显示 Fixed Volume，也没有硬件音量能力路由。后续实现时不得为了复用普通音频音量滑块而改写 DoP sample。

## 8. 建议的下一阶段顺序

建议先把“一个 DSF 正常播放”的结果加固，再扩大格式范围：

1. **播放稳定性**：共享 marker timeline、underrun 诊断、设备断开/占用错误、长时间播放和暂停恢复。
2. **真实 Seek**：增加 Runtime seek command，使 UI 进度条可操作；seek 对齐到 16 DSD sample，并重置 DoP phase。
3. **现有列表接入**：多个 DSF/DFF 形成 `PlaybackQueueSnapshot` 和 `NavigatorContribution`；实现上一项、下一项、选择项和当前项同步。
4. **raw DFF 播放**：实现 DFF source 并复用现有 `DSDStream → DoP → HAL` 管线。
5. **PCM fallback**：内置扬声器、蓝牙和不支持目标 carrier 的设备必须可播放；再实现 Automatic / Prefer DoP / Always PCM 策略。
6. **metadata、封面、设置与 Session 恢复**。
7. **DST 与 SACD ISO**：按主技术方案接入同一 queue/navigator，不生成临时 DSF。
8. **服务隔离和发布**：评估将 application-scope audio service 移至独立 Engine Service/XPC，并完成正式插件安装、升级与签名流程。

Phase 1 的真正验收不是“parser 能读 DFF”，而是：DSF/DFF 能从 Finder、拖放和批量列表进入同一宿主体验；DoP 不可用时自动 PCM；Seek、切歌、设备切换和恢复均不破坏音频设备状态。

## 9. 新会话启动清单

新 agent 开始工作时：

1. 读取仓库根目录 `AGENTS.md`、本文和 `foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md`。
2. 执行 `git status --short`；当前工作可能尚未提交，必须保留用户已有修改，不得 reset。
3. 运行 15 项 Hi-Fi 核心测试和相关 ExtensionKit 测试，建立基线。
4. 不要重新猜测 176.4 kHz 的来源，也不要重做已经通过的 DoP silence/Hog Mode spike。
5. 修改 DoP encoder、DSF bit order、physical/virtual format 或 callback layout 前，先阅读本文第 2、3、5 节并补回归测试。
6. 完成 app 代码变更后按仓库要求执行 `./run`，让用户直接进行硬件验收。

## 10. 关联文档

- 总体技术方案：`foofoil/docs/foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md`
- 扩展系统方案：`foofoil/docs/foofoil_Extension_System_Implementation_Plan.md`
- 扩展部署记录：`foofoil/docs/phase0-extensionkit-deployment.md`
- DoP open Standard 1.1：<https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf>
- Sony DSF File Format Specification 1.01：<https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf>

