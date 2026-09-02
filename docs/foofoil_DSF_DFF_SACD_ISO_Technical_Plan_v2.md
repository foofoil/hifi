# foofoil Hi-Fi 插件：DSF / DFF / SACD ISO 技术方案

> 文档状态：基于 foofoil 已具备扩展系统、内容 Provider、Content Session、通用列表与 Navigator Host 的现状重新设计（v2）。
>
> 核心结论：DSF、DFF、SACD ISO、DST、DoP、DSD → PCM、专业设备路由等高级音频能力不进入 foofoil Core，而由第一方可选组件 **Hi-Fi** 提供；SACD ISO 等多曲目内容使用 foofoil 现有列表界面呈现，不在插件中另造曲目列表 UI。

---

## 1. 背景与调整原因

旧方案建立在“高级音频直接集成到主程序、项目仍以单文件查看为主”的前提上，因此把 Reader、播放控制、曲目列表和 CoreAudio HAL 都规划在 foofoil 内部。

现在项目已经具备：

- Extension Manager、Registry、安装、升级与卸载机制；
- Content Request、Provider Resolver 与 Content Session；
- capability negotiation、命令贡献与状态恢复框架；
- 图片、视频、音频共用的文件列表能力；
- 通用 Navigator Panel，可呈现一维列表与树形结构；
- `NavigatorContribution` 及 activate、remove、move 等宿主动作；
- 多文件请求与安全范围书签管理。

因此高级音频的正确边界已经变化：

```text
foofoil Core
├── 浮动窗口与通用音频外壳
├── Provider 选择与 Session 生命周期
├── 列表 / Navigator Host
├── 菜单、快捷键、本地化与辅助功能
├── 扩展安装、验证、升级、禁用和恢复
└── 系统原生普通音频 Provider

Hi-Fi 插件
├── 高级音频格式识别与解析
├── DSF / DFF / SACD ISO / DST
├── DSDStream 与播放队列语义
├── DoP 与 DSD → PCM
├── CoreAudio HAL、设备探测与独占输出
├── 高级音频 metadata
└── 音频领域设置与命令状态
```

这次调整不是把旧实现机械搬进插件，而是重新定义 Core 与 Hi-Fi 之间的会话协议、列表所有权、实时音频边界和失败回退。

---

## 2. 产品定义与范围

Hi-Fi 是 foofoil 官方维护、按需安装的第一方插件，不是独立音乐播放器，也不是音乐资料库。

```text
打开 album.dsf / album.dff
        ↓
foofoil 发现 Hi-Fi 可处理
        ↓
已安装：直接建立 Hi-Fi Session
未安装：提示安装 Hi-Fi，完成后继续打开
```

```text
打开 album.iso
        ↓
Hi-Fi sniff 确认为 SACD ISO
        ↓
解析 Area 与 Track
        ↓
foofoil 现有列表面板显示曲目
        ↓
选择曲目后由同一 Hi-Fi Session 播放
```

Hi-Fi 也可以作为普通音频的增强 Provider，按用户偏好接管 MP3、AAC、ALAC、FLAC、WAV、AIFF 等会话，以提供统一播放队列、输出设备选择和专业输出能力。普通音频始终保留 Built-in Audio Provider 作为回退。

### 2.1 第一阶段：Hi-Fi 基础链路

- Hi-Fi Provider 的安装、识别、启动、失败提示与状态恢复；
- 单文件与多文件 `ContentRequest`；
- DSF：DSD64 / DSD128 / DSD256、Stereo；
- DFF / DSDIFF：raw DSD 与 DST 压缩 DSD；
- metadata 与封面；
- 播放、暂停、Seek、上一项、下一项；
- 复用 foofoil 音频列表和 Navigator Panel；
- DoP 输出与 DSD → PCM 自动降级；
- 输出设备能力检测、设备选择与插拔恢复；
- Exclusive / Hog Mode；
- 与 Built-in Audio Provider 的明确选择和回退。

### 2.2 第二阶段：SACD ISO

- 通过 content sniffing 区分 SACD ISO 与普通 `.iso`；
- SACD Stereo / 2CH Area；
- Track 枚举、metadata、时长和选择；
- 使用现有列表 UI 呈现 ISO 曲目；
- ISO 中 raw DSD 与 DST → DSD；
- Track 内 Seek、相邻 Track gapless；
- 会话与当前曲目恢复。

### 2.3 后续评估

- SACD Multichannel Area；
- APE、WavPack 等其他高级格式；
- 更高质量且可配置的 DSD → PCM 滤波；
- 音频可视化与有限的音效能力；
- Native DSD，仅在 macOS 与目标设备存在可靠、可验证通路时考虑。

### 2.4 非目标

- 音乐目录扫描与后台入库；
- Artist / Album / Genre 曲库数据库；
- 在线音乐服务、账号或云端处理；
- 自动整理、移动或重命名用户文件；
- SACD 抓轨、ISO 修改或制作工具；
- VST / AU 插件宿主；
- DSD 升频、PCM → DSD 与 HQPlayer 式复杂 DSP；
- 插件自绘一套与 foofoil 不一致的播放列表窗口。

“列表”只表示当前会话中的可播放项目：用户打开的一组文件、CUE 曲目或容器内部 Track。它不是持久化音乐资料库。

---

## 3. 设计原则

### 3.1 Core 保持轻量

所有只服务于高级音频的解析器、decoder、HAL 输出与第三方 native code 都随 Hi-Fi 分发。未安装 Hi-Fi 时，它们不增加 foofoil 主程序的二进制体积、启动成本和常驻内存。

Core 只理解稳定的通用概念：

```text
ContentRequest
ContentSession
MediaPlaybackQueue
NavigatorContribution
CommandDescriptor
可序列化状态和事件
```

Core 不理解 DSD sample layout、DST frame、SACD sector、DoP marker 或某个 DAC 的格式能力。

### 3.2 复用列表，不复制 UI

Hi-Fi 负责队列语义和项目数据，foofoil 负责列表的原生呈现、选择、键盘导航、辅助功能、伴随窗口与全屏覆盖层。

必须区分两层：

- `media.playback-queue`：顺序、当前项、自动续播、重排、移除、gapless 和恢复；
- `ui.navigator`：把队列或容器目录转换为宿主可展示的列表/树快照，并接收用户动作。

Hi-Fi 通常同时提供两种 capability。不能把 Navigator 当成播放队列本身，也不能让 Core 从列表行反推播放语义。

### 3.3 DSD 优先保持 DSD

```text
DSF / DFF / SACD ISO
          ↓
       DSDStream
          ↓
       DoPEncoder
          ↓
    CoreAudio HAL
          ↓
      USB Audio DAC
```

DoP 只封装 DSD payload，不执行 DSD → PCM。链路中不得发生 SRC、混音、软件音量缩放或 DSP 修改。

### 3.4 DoP 不可用时保证可播放

```text
DSDStream → DSDPCMDecoder → PCM Output → 当前设备
```

Mac 内置扬声器、蓝牙设备、普通 PCM DAC、无法提供所需 carrier rate 的设备或独占初始化失败时，默认自动降级为 PCM，而不是把内容判定为不可播放。

### 3.5 不把容器曲目伪装成独立文件

SACD ISO 是一个外部受权资源，Track 是其中的逻辑项目。不能为每个 Track 创建相同路径的 `FileListItem`，也不能生成临时 DSF 来迎合“每项一个 URL”的模型。

```text
一个 ExtensionResource: album.iso
一个 Hi-Fi ContentSession
一个 MediaPlaybackQueue
多个稳定 Track ID
一个由 Track 快照生成的 NavigatorContribution
```

安全范围授权覆盖 ISO 资源；曲目 ID、Area、时间位置等属于插件会话状态。

---

## 4. 宿主与插件职责

| 能力 | foofoil Core | Hi-Fi 插件 |
|---|---|---|
| 扩展发现、安装、验签、升级 | 负责 | 提供 manifest 与发行产物 |
| 内容路由 | 运行 Provider Resolver | 声明匹配规则并 sniff 内容 |
| 文件安全范围授权 | 创建书签并定义授权生命周期 | Engine Session 解析书签并成组持有/释放访问 |
| 普通音频基础播放 | Built-in Provider | 可选择性增强或接管 |
| DSF / DFF / SACD ISO | 不解析 | 负责 |
| DST、DSD → PCM、DoP | 不实现 | 负责 |
| 设备探测与 HAL 实时输出 | 不理解协议细节 | 负责 |
| 曲目/队列语义 | 转发通用动作 | 负责并维护真实状态 |
| 列表外观和交互 | 使用现有 Navigator Host | 提供值类型快照 |
| 菜单与快捷键 | 构造、校验、路由 | 提供命令描述和执行结果 |
| 本地化 chrome | 负责 | 提供已注册 localization key |
| metadata 内容值 | 展示 | 解析和更新 |
| Session 恢复载荷 | 限额、持久化、损坏回退 | 定义 schema 并迁移 |
| 播放失败回退 | 按 Resolver 结果协调 | 返回结构化失败原因 |

Hi-Fi 不向 Core 暴露 Swift/C++ decoder 对象、`NSView`、`NSImage`、文件描述符内部状态或 HAL callback。边界使用稳定标识、值类型、资源引用、命令和事件。

---

## 5. 扩展声明与 Provider 选择

Hi-Fi 建议使用独立仓库和独立 Release：

```text
foofoil/foofoil-extension-hifi
```

Manifest 概念示例：

```json
{
  "id": "app.foofoil.extension.hifi",
  "name": "Hi-Fi",
  "providers": [{
    "id": "audio.hifi",
    "role": "override",
    "fallbackProvider": "builtin.audio",
    "contentTypes": [
      {"extensions": ["dsf", "dff"], "strategy": "extension"},
      {"extensions": ["iso"], "strategy": "sniff"},
      {"utTypes": ["public.audio"], "strategy": "conforms"}
    ]
  }],
  "capabilities": [
    "audio.dsd",
    "audio.dop",
    "media.playback-queue",
    "ui.navigator",
    "audio.device-selection",
    "audio.exclusive",
    "ui.music-commands"
  ]
}
```

`.iso` 不能只按后缀接管。Hi-Fi 先进行轻量、有上限的头部与目录结构 sniff，确认存在有效 SACD 结构后才返回强匹配；普通磁盘 ISO 必须留给其他 Provider 或显示不支持。

Provider 选择遵循现有规则：

1. 用户对音频域的显式 Provider 偏好；
2. DSF、DFF 或已确认的 SACD ISO 等强匹配；
3. 已安装且运行时可用的 Hi-Fi 增强 Provider；
4. Built-in Audio Provider；
5. manifest 声明的失败回退。

对于 DSF、DFF、SACD ISO，Built-in 通常没有可用回退；缺少或禁用 Hi-Fi 时显示“安装/启用 Hi-Fi”占位状态。对于系统原生格式，Hi-Fi 启动失败后可回退 Built-in。

---

## 6. Content Request 与 Session

### 6.1 请求形态

```text
singleFile(resource)
├── 单个 DSF / DFF
└── 单个 SACD ISO

fileCollection(resources)
├── 多个 DSF / DFF
└── 用户拖入或打开的一组普通/高级音频

restoredSession(extensionID, stateReference)
└── 恢复 Provider、队列、当前项和播放位置
```

SACD ISO 中的多个 Track 不扩展成 `fileCollection`；它们没有独立安全范围资源，属于 `singleFile(iso)` 建立后的容器内部队列。

### 6.2 Session 状态

```text
HiFiSessionState
├── sessionID
├── sourceResources[]
├── queueItems[]
│   ├── stableID
│   ├── sourceReference
│   ├── containerTrackReference?
│   ├── title / artist / album / duration
│   └── playable / failure state
├── currentItemID
├── playbackPosition / playbackState
├── repeatMode / shuffleMode
├── selectedOutputDeviceID?
├── outputPolicy
└── currentOutputStatus
```

Core 只保存有 namespace、schema version 和大小限制的序列化状态引用。恢复时重新解析书签，重新验证文件身份与 Track 映射；不能持久化裸指针、sector offset 或进程相关句柄。

### 6.3 稳定 ID

列表 ID 不能依赖行号，否则 metadata 补全、Area 切换或重新解析后会丢失选择。建议：

```text
外部文件项：resource identity + provider-local item identity
SACD Track：disc identity + area identity + track number/index
```

ID 在可恢复会话与当前内容版本内稳定，不包含用户可见标题。检测到 ISO 被替换或修改时，使旧索引失效并重新建立。

---

## 7. 复用 foofoil 列表能力

### 7.1 多文件音频

Core 负责收集资源、去重、创建书签并构造 `fileCollection`。Hi-Fi Engine Session 将其解释为播放队列，并在会话生命周期内成组持有资源访问，向 Core 发布与现有音频列表一致的 Navigator 快照：

- activate：切换当前项；
- remove：从会话队列移除，不删除磁盘文件；
- move：调整播放顺序；
- 上一项/下一项、播完续播、循环和随机作用于队列；
- 当前项、badge、选中状态由插件更新后回传；
- 插件不维护第二套可见列表 UI。

### 7.2 SACD ISO 曲目

```text
NavigatorContribution
├── id: hifi.sacd.tracks
├── style: flat
├── selectionMode: single
├── items
│   ├── track:stereo:01  01 Allegro con brio  [15:22]
│   ├── track:stereo:02  02 Andante           [10:31]
│   └── track:stereo:03  03 Scherzo           [05:18]
├── selectedItemIDs: [currentTrackID]
└── allowedActions: [activate]
```

第一版 ISO 曲目由光盘结构决定，不允许 remove 或 move。后续若支持“自定义会话播放顺序”，应另建 queue contribution，不能修改 SACD 物理目录的顺序含义。

若加入 Multichannel，可使用现有 outline：

```text
SACD Tracks
├── Stereo
│   ├── Track 01
│   └── Track 02
└── Multichannel
    ├── Track 01
    └── Track 02
```

### 7.3 与当前 `FileListState` 的关系

现有 `FileListState` 和 `FileListItem` 适合 Built-in Provider 的“一个项目对应一个外部文件”场景，也已支持 CUE 分段。Hi-Fi 不直接依赖这些 Core 内部 Swift 类型作为跨 Release ABI。

```text
Built-in FileListState ─┐
                       ├→ Navigator Host → 同一套列表 UI
Hi-Fi Contribution ────┘
```

若以后抽取统一公共队列 contract，应增加 versioned 值类型并保持旧 Session 可解码，而不是把 `FileListCueInfo` 扩展成 SACD 专用数据结构。

### 7.4 增量更新

SACD Track 初次解析可以分阶段返回：

1. 建立 Session，显示“正在读取曲目”；
2. 得到 TOC 后发布标题和 Track 数；
3. metadata/时长补全后提高 contribution `revision`；
4. 播放状态变化时只更新当前项、选择和必要 badge。

第一版可接受低频完整快照；播放进度留在播放状态通道，不为每个音频 buffer 重发列表。

---

## 8. Hi-Fi 内部架构

```text
                         foofoil Core
              ┌───────────────────────────┐
              │ Provider Resolver         │
              │ Content Session Host      │
              │ Audio UI / Navigator Host │
              └─────────────┬─────────────┘
                            │ commands / snapshots / events
                            │
                  Hi-Fi Engine Service
              ┌─────────────┴─────────────┐
              │ HiFiSessionController     │
              │ PlaybackQueue             │
              │ Metadata / State          │
              └─────────────┬─────────────┘
                            │
                       AudioSource
          ┌─────────────────┼─────────────────┐
          │                 │                 │
      DSFSource         DFFSource         SACDSource
          │                 │           Area / Track
          │            raw / DST          raw / DST
          └─────────────────┴─────────────────┘
                            │
                         DSDStream
                            │
                 ┌──────────┴──────────┐
                 │                     │
             DoPEncoder           DSDPCMDecoder
                 │                     │
                 └──────────┬──────────┘
                            │
                    HALAudioOutput
                            │
                      CoreAudio Device
```

所有 DSD 来源最终收敛到 `DSDStream`。容器差异不能泄漏到 DoP、PCM fallback、设备探测或列表 UI。

---

## 9. 插件进程与实时音频边界

高级解析器、DST decoder 和第三方 native code 处理不受信文件，Hi-Fi 应优先以独立 Engine Service 运行。实时输出必须有单一所有者：

```text
Hi-Fi Engine Service
├── 文件读取与解码 worker
├── bounded ring buffer
├── CoreAudio HAL device ownership
└── realtime callback

foofoil Core
└── 只收发控制命令与低频状态，不搬运实时音频帧
```

不通过普通 XPC 消息逐 buffer 把 DoP 或高采样率 PCM 送回 Core，因为 IPC jitter、复制和背压会破坏实时性。Engine Service 拥有从 decoder 到 HAL 的完整链路。

Phase 0 必须验证：

- 扩展服务能否可靠枚举和打开 CoreAudio 设备；
- 安全范围文件授权能否在服务中正确建立和回收；
- Hog Mode 与设备属性恢复是否能跨服务异常退出保持安全；
- 服务崩溃后 Core 能否显示失败并重新建立 Session；
- 签名、sandbox/entitlement 和发布结构是否符合扩展系统约束。

若部署限制迫使第一版进程内运行，也保持相同的可序列化协议边界，为迁移服务保留路径。

---

## 10. 核心音频抽象

以下是 Hi-Fi 内部概念，不作为 Swift ABI 暴露给 foofoil：

```swift
protocol AudioSource {
    var metadata: AudioMetadata { get }
    var duration: TimeInterval { get }
    var items: [PlayableItem] { get }
    func open(itemID: String) throws -> AudioStream
}

struct DSDFormat {
    let sampleRate: Int
    let channels: Int
    let bitOrder: DSDBitOrder
}

protocol DSDStream {
    var format: DSDFormat { get }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    func seek(toSample sample: UInt64) throws
}
```

`PlayableItem` 可以引用完整文件、CUE 范围或 SACD Track，但输出管线只看到一个已打开的音频流。

---

## 11. DSF、DFF 与 SACD Reader

### 11.1 DSF

读取 `DSD `、`fmt `、`data` chunk，获得 channel count、sample rate、sample count、block size，并读取 ID3 metadata 与封面。第一版覆盖 DSD64、DSD128、DSD256 与 Stereo。

Seek 使用 sample、block size 和 channel layout 建立偏移映射；Seek 后重建 DoP marker phase。DSF 较简单，优先评估小型本地实现或窄范围复用，不为它引入完整媒体框架。

### 11.2 DFF / DSDIFF

处理 `FRM8`、`FVER`、`PROP`、`FS  `、channel layout、raw `DSD ` chunk、DST frame/index 和可用 metadata。

```text
DFF raw DSD ───────────────┐
                           ├→ DSDStream
DFF DST → DSTDecoder ──────┘
```

DFF 与 SACD 都可能使用 DST，因此 DFF/DST 在 SACD 之前完成。DST Seek 从可解码 frame 边界恢复，并建立有上限的轻量索引。

### 11.3 SACD ISO

```text
SACD ISO → Scarlet Book / TOC → Area → Track
         → Audio Frames → raw DSD / DST → DSDStream
```

第二阶段先支持 Stereo Area。Reader 同时产生：

- 稳定 Area / Track 标识；
- 曲目顺序、标题、时长及可用 metadata；
- Track → frame / sector 的 seek index；
- 可供 `PlaybackQueue` 和 `NavigatorContribution` 使用的快照；
- 打开指定 Track 的流式 `DSDStream`。

DST 是无损 DSD 压缩，`DST → DSD` 后仍可进入 DoP，不等同于 DSD → PCM。

正式实现不采用 `ISO → 临时 DSF → 播放`，避免首次等待、磁盘占用、SSD 写入、临时文件生命周期和 Track 切换问题。开发 spike 可临时提取作为数据正确性的对照。

不建议从零实现完整 Scarlet Book 与 DST。应评估 `sacd_extract` / sacd-ripper 中可合法复用的代码，包装为 Hi-Fi 内部流式 library，不运行外部 CLI。

---

## 12. DoP、PCM fallback 与输出路由

### 12.1 DoP

`DoPEncoder` 是纯流式转换器，不做 SRC、音量、EQ、混音或浮点转换。

| DSD | DSD Rate | DoP Carrier |
|---|---:|---:|
| DSD64 | 2.8224 MHz | 176.4 kHz |
| DSD128 | 5.6448 MHz | 352.8 kHz |
| DSD256 | 11.2896 MHz | 705.6 kHz |

设备宣传“支持 DSD256”不代表 macOS CoreAudio 一定允许 705.6 kHz 的适合 physical format，必须实际枚举和设置。

### 12.2 设备能力探测

禁止按 DAC 名称或厂商白名单判断：

1. 计算当前 DSD rate 所需 carrier；
2. 查询目标 `AudioDevice` 的 stream physical formats；
3. 匹配 sample rate、channel count、bit depth 与 packing；
4. 尝试取得独占并设置 physical format；
5. 建立 HAL output；
6. 全部成功后才报告 DoP active。

设备重连、默认设备变化、睡眠唤醒或属性变化后使缓存失效。

### 12.3 自动策略

```text
打开 DSD → Probe 设备
   ├── 支持 → 尝试 Exclusive / HAL / DoP
   │            ├── Success → DoP
   │            └── Failure → PCM fallback
   └── 不支持 → PCM fallback
```

设置建议为 Automatic、Prefer DoP、Always convert to PCM，默认 Automatic。

### 12.4 DSD → PCM 与音量

第一版目标是正确、稳定、CPU 成本合理、不爆音和不削波。采样率优先选择 44.1 kHz family：352.8、176.4、88.2、44.1 kHz，并根据设备能力与 CPU 成本降级。

DoP 下禁止软件音量。有硬件音量时控制设备属性；没有时禁用软件音量，并显示 Fixed Volume / Bit-perfect。PCM fallback 可使用正常音量策略。

---

## 13. 实时线程、Seek 与 gapless

HAL callback 中禁止文件 I/O、malloc/free、Swift async/await、长锁等待、DST 解码、DSD → PCM 重计算和 XPC 往返。

```text
Reader / Decoder worker → bounded ring buffer → HAL realtime callback
```

Seek 由各 Source 把逻辑时间映射到可解码位置：DSF/DFF raw 映射到 sample/block，DST 映射到 frame 边界，SACD 映射到 Track 内 frame/sector。UI 和 Core 不理解这些细节。

连续曲目不在 Track 边界 teardown 设备：

```text
Decoder A ──┐
            ├→ shared ring buffer → HAL
Decoder B ──┘
```

下一项提前 prepare。相邻项目的 sample rate、channel layout 和输出模式一致时复用设备链路；不一致时受控重配置并明确 gapless 不可保证。SACD Track 和多文件列表共用这一调度机制。

---

## 14. 设备变化与多窗口

设备拔出或切换时：

```text
停止/排空 HAL
→ 释放 Hog Mode
→ 恢复插件修改过的设备属性
→ probe 新设备
→ 选择 DoP 或 PCM
→ 从安全位置恢复播放
```

覆盖设备拔出、默认设备改变、设备被占用、sleep/wake、Engine Service 崩溃、foofoil 退出、插件禁用/升级和多窗口竞争。

第一版由 Hi-Fi 的 application-scope audio service 串行协调设备独占。多个窗口可以各自有队列，但同一时刻只能有一个拥有独占输出；切换活动播放会话时显式停止或暂停前一会话。

---

## 15. UI、状态与错误

foofoil 保留内容窗口、封面、通用播放控件、Navigator Panel 和菜单。Hi-Fi 提供状态，例如：

```text
DSD64 · DoP · SMSL USB AUDIO
DSD64 → PCM 176.4 kHz · Mac Speakers
```

插件通过 `CommandDescriptor` 贡献输出设备、输出策略、Exclusive Mode、循环/随机和后续音效入口。Core 负责本地化、菜单、快捷键冲突、活动窗口路由和辅助功能。插件不传递 `NSMenu` 或 SwiftUI View 作为长期协议。

会话状态建议：

```text
idle → openingSource → readingMetadata / indexing
→ probingDevice → preparingDoP / preparingPCM
→ ready / playing ↔ paused → stopped
```

错误至少区分 invalidDSF、invalidDFF、invalidSACDISO、unsupportedArea、DSTDecodeFailure、seekIndexFailure、deviceDisconnected、deviceBusy、unsupportedDoPRate、exclusiveModeFailure、outputInitializationFailure、resourceAuthorizationFailure 和 engineServiceUnavailable。

- DoP 初始化失败：通常可转 PCM；
- metadata/封面失败：可继续播放；
- 单个队列项损坏：标记不可播放并可继续下一项；
- ISO 无效或 DST decoder 失败：当前内容不可播放；
- Hi-Fi 接管普通音频失败：可回退 Built-in；
- Hi-Fi 专属格式失败：保留占位和重试入口。

用户可见文本必须进入本地化资源，英语和简体中文保持完整；Track 标题等媒体内容值不需要本地化。

---

## 16. 依赖与许可证

优先使用 Foundation、CoreAudio、AudioToolbox、AVFoundation 和 ImageIO。只在 Hi-Fi 内补充 DSF/DFF parser、DST decoder、SACD parser、DoP encoder 与 DSD → PCM。

候选实现：

- SFBAudioEngine：评估 DSF、DSDIFF、DoP、DSD → PCM、可裁剪范围、许可证和体积；
- sacd_extract / sacd-ripper：评估 Scarlet Book、Area/Track、frame 读取与 DST decoder。

默认不引入 Qt、完整 FFmpeg、大型跨平台播放器、媒体库框架或完整 DSP framework。任何第三方代码进入前必须确认许可证与 notices、可裁剪体积、安全记录、arm64/macOS 支持、服务隔离能力和传递依赖。

不要假设旧方案提到的库一定适用；Phase 0 重新做技术与法务评估。

---

## 17. 测试方案

### 17.1 协议与宿主集成

- 未安装 Hi-Fi 时的安装提示及安装后继续打开；
- 普通音频 Built-in / Hi-Fi 偏好与失败回退；
- `singleFile`、`fileCollection`、restored session；
- 书签建立、恢复、失效与释放；
- Navigator revision、activate/remove/move 与非法动作拒绝；
- SACD Track 只开放允许动作；
- 插件禁用、升级、崩溃与重连；
- 多窗口活动会话和命令路由。

### 17.2 文件矩阵

```text
DSF：DSD64/128/256 Stereo；有/无 metadata；损坏、截断、大封面
DFF：raw/DST DSD64/128；异常 chunk、frame、channel layout
ISO：Stereo raw/DST；Stereo+Multichannel；多 Track/gapless；
     大型、损坏及普通非 SACD ISO
```

测试素材必须确认来源和再分发权；不能把受版权保护的商业 SACD 镜像提交到仓库。解析器配套最小合法 fixture、corruption case 和边界测试。

### 17.3 设备、实时性与体积

- Mac internal speakers、Bluetooth/AirPods、普通 USB PCM DAC、至少两款 DoP DAC；
- DAC 确认显示 DSD64/128/256，而非仅有声音；
- marker、pause/resume、Seek、切 Track、gapless、underrun；
- unplug/replug、sleep/wake、设备抢占、Hog 失败和属性恢复；
- Service 崩溃是否遗留设备状态；
- foofoil 未安装插件时的体积/启动不变；
- 插件体积、冷启动、首帧、各格式 CPU/内存和长时稳定性。

SMSL D6s 可作为参考设备，但不得硬编码名称或厂商 ID。

---

## 18. 实施阶段

### Phase 0：扩展边界与音频 Spike

```text
ContentRequest
→ Hi-Fi Engine Service
→ DSF / raw DFF / DST DFF
→ DSDStream
→ DoP DAC 或 PCM Mac Speakers
→ Session 状态回传
```

同时构造静态 Track 队列，通过真实 `NavigatorContribution` 在现有列表面板中完成 activate、当前项更新和上一首/下一首。

验收：

1. Provider 可安装、匹配并建立 Session；
2. Engine Service 部署、文件授权和 HAL 访问成立；
3. DSF、raw DFF、DST DFF 可稳定读取；
4. 参考 DAC 正确识别 DSD64/128；
5. 内置输出自动降级 PCM；
6. 列表复用链路成立，没有插件自定义列表 UI；
7. Service 异常退出后释放或恢复设备；
8. 完成候选依赖许可证和体积报告。

### Phase 1：DSF / DFF 可发布版本

完成 Reader、metadata、DST、DoP、PCM fallback、HAL、Seek、设备切换、多文件队列、Session 恢复、设置与本地化。

验收：用户双击、拖入或批量打开 DSF/DFF 时，行为与 foofoil 其他内容一致；列表、菜单和快捷键使用宿主能力；未安装插件时能从应用内安装并继续打开。

### Phase 2：SACD ISO

完成 sniff、Stereo Area、Track 枚举、raw/DST 流、Track Seek、gapless、曲目 Navigator 与恢复。

验收：一个 ISO 建立一个 Session，所有 Track 在现有列表中可导航；不生成临时 DSF，不把 Track 伪装成多个外部文件，也不接管普通非 SACD ISO。

### Phase 3：增强能力

按实际需求评估 Multichannel、APE/WavPack、可视化、更高质量滤波和 Native DSD。每项独立评估体积、实时性、宿主 contract 与新 capability，不能因同属 Hi-Fi 自动扩大范围。

---

## 19. 第一版技术决策

| 项目 | 决策 |
|---|---|
| 产品形态 | 第一方可选 Hi-Fi 插件 |
| Core 体积 | 不携带高级 codec/parser/HAL 实现 |
| 普通音频 | Built-in 保留；Hi-Fi 可按偏好 override |
| DSF / DFF | Phase 1 |
| DFF DST | 与 DFF 同阶段，复用到 SACD |
| SACD ISO | Phase 2，先 Stereo Area |
| `.iso` 匹配 | 必须 content sniffing |
| SACD Track | 同一资源/Session 内的逻辑队列项 |
| 列表 UI | 复用 foofoil Navigator Host |
| 队列语义 | Hi-Fi 的 `media.playback-queue` |
| 列表数据 | versioned `ui.navigator` contribution |
| 插件 UI | 不自绘播放列表；命令和状态由宿主呈现 |
| DSD 输出 | DoP 优先 |
| DoP 输出 | Hi-Fi Engine Service 内 CoreAudio HAL |
| DoP 不可用 | 自动 DSD → PCM |
| Exclusive | DoP 时尽量 Hog Mode，失败可降级 |
| ISO 播放 | 流式，不生成临时 DSF |
| Native DSD | 第一版不做 |
| 依赖 | 只放入 Hi-Fi，重新评估许可证与裁剪成本 |
| 音乐曲库 | 不做 |

---

## 20. 关键风险

### 20.1 扩展服务与 HAL 的部署可行性

签名、sandbox、entitlement、XPC 生命周期和安全范围授权可能限制独立服务直接管理设备。这是 Phase 0 的阻断性验证项。

### 20.2 CoreAudio 不自动等于 bit-perfect

必须实测 physical format、SRC/mixer 绕过、Hog Mode、buffer layout 和 DoP marker。设备规格不能替代运行时验证。

### 20.3 列表复用不等于复用文件路径模型

把 SACD Track 塞入 `FileListItem.path` 会导致重复 URL、错误书签、历史恢复歧义和容器 Seek 泄漏。应复用 Navigator Host，让 Track 保持插件内部逻辑 ID。

### 20.4 多窗口与独占设备冲突

播放 Session 属于窗口，物理设备独占属于应用范围。必须有 Hi-Fi application service 仲裁，不能让每个窗口独立取得 Hog Mode。

### 20.5 软件音量与 DoP 冲突

UI 从第一版接受 DoP 的 Fixed Volume 状态，不能为了保留滑块破坏 bitstream。

### 20.6 插件升级与恢复兼容

Hi-Fi 与 foofoil 独立发版。队列、Track ID 和设置状态需要 schema version、迁移和损坏回退；旧 Session 不能依赖 decoder 私有二进制布局。

---

## 21. 建议下一步

先完成两个相互打通的 Spike：

```text
Spike A：扩展与列表
安装 Hi-Fi → 建立测试 Session
→ 发布 playback queue / navigator
→ 使用 foofoil 现有列表完成选择与状态同步

Spike B：实时音频
DSF / raw DFF / DST DFF → DSDStream
→ Engine Service → DoP DAC 或 PCM fallback
```

合并后验证“列表选择下一项 → 插件切换源 → 保持/重建输出链路 → Core 更新当前项”的完整闭环。闭环成立后进入 DSF/DFF 产品化；SACD ISO 只新增容器、Area、Track 与索引层，并接入已验证的队列、Navigator、DST、DSDStream 和输出管线。

---

## 22. 参考

- foofoil 扩展系统实施方案：`foofoil/docs/foofoil_Extension_System_Implementation_Plan.md`
- SFBAudioEngine：https://github.com/sbooth/SFBAudioEngine
- sacd_extract / sacd-ripper：https://github.com/jmmaloney4/sacd-extract
- Apple Core Audio / Audio Hardware Services 文档

参考实现只用于技术评估，不代表已完成许可证、安全、体积或维护成本审批。
