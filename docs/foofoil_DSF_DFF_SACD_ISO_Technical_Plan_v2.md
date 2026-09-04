# foofoil Hi-Fi 插件：DSF / DFF / SACD ISO 技术方案

> 文档状态：2026-09-04 按三个独立仓库的现行实现与硬件验收结果校准（v2）。`foofoil` 是宿主应用，`extension-kit` 是稳定扩展契约，`hifi` 是独立第一方扩展。
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
├── 外部文件列表、播放顺序与 Navigator Host
├── 菜单、快捷键、本地化与辅助功能
├── 扩展安装、验证、升级、禁用和恢复
└── 系统原生普通音频 Provider

FoofoilExtensionKit
├── Manifest / Provider / Content Session 值类型
├── contentFamily 与 capability contracts
└── 跨仓库稳定 C ABI / JSON 消息边界

Hi-Fi 插件
├── 高级音频格式识别与解析
├── DSF / DFF / SACD ISO / DST
├── DSDStream 与容器内部 Track 语义
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

将来 Hi-Fi 可以作为普通音频的增强 Provider，按用户偏好接管 MP3、AAC、ALAC、FLAC、WAV、AIFF 等解码或输出能力。当前 `0.1.0` manifest 只声明 `.dsf`，普通音频始终由 Built-in Audio Provider 播放；两类文件已经共享同一个宿主音频列表。

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

### 3.2 统一列表归宿主，解码按当前项目路由

外部音频文件不因解码器不同而拆成两种列表。MP3/FLAC 等普通音频和 DSF/DFF 等扩展音频统一进入 foofoil 的 `FileListState(kind: .audio)`；拖入、去重、排序、移除、当前项、循环/随机、自动续播、键盘操作、动态图标和持久化均由宿主实现。用户选择某一项后，宿主才调用 Provider Resolver，决定由 Built-in Audio 还是 Hi-Fi 解码。

必须区分两类项目：

- **外部文件项**：真实 URL 和书签由宿主列表持有，Hi-Fi 每次只建立当前文件的播放 Session，不复制列表顺序；
- **容器虚拟项**：SACD ISO Track 没有独立 URL，未来由版本化的虚拟媒体项/queue contract 表达，插件维护 Track 真相，宿主负责呈现和交互。

`media.playback-queue` 与 `ui.navigator` 仍保留，用于兼容旧的多文件 Session、容器 Track 和未来跨扩展协议；它们不是当前 DSF 外部文件列表的所有权依据。不能让插件自绘第二套列表，也不能让 Core 理解 SACD sector 等解码细节。

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
| 外部文件列表与播放顺序 | 负责并维护唯一真实状态 | 只播放当前路由到插件的文件 |
| SACD 容器 Track 语义 | 持有通用虚拟媒体项并转发动作 | 解析并维护 Track 真实状态 |
| 列表外观和交互 | 使用现有 FileList / Navigator Host | 为虚拟 Track 提供值类型快照 |
| 菜单与快捷键 | 构造、校验、路由 | 提供命令描述和执行结果 |
| 本地化 chrome | 负责 | 提供已注册 localization key |
| metadata 内容值 | 展示 | 解析和更新 |
| Session 恢复载荷 | 限额、持久化、损坏回退 | 定义 schema 并迁移 |
| 播放失败回退 | 按 Resolver 结果协调 | 返回结构化失败原因 |

Hi-Fi 不向 Core 暴露 Swift/C++ decoder 对象、`NSView`、`NSImage`、文件描述符内部状态或 HAL callback。边界使用稳定标识、值类型、资源引用、命令和事件。

---

## 5. 扩展声明与 Provider 选择

Hi-Fi 已从宿主拆为独立兄弟仓库，并独立 Release。开发工作区布局为：

```text
foofoil/         # 宿主应用
extension-kit/   # 扩展契约 Swift Package
hifi/            # Hi-Fi 扩展
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
    "enhancementDomain": "audio",
    "contentFamily": "audio",
    "contentTypes": [
      {"extensions": ["dsf"], "strategy": "extension"}
    ]
  }],
  "capabilities": [
    {"id": "session.seekable", "contractVersion": 1, "scope": "session"},
    {"id": "media.playback-queue", "contractVersion": 1, "scope": "session"},
    {"id": "audio.device-selection", "contractVersion": 1, "scope": "application"},
    {"id": "ui.commands", "contractVersion": 1, "scope": "presentation"},
    {"id": "ui.navigator", "contractVersion": 1, "scope": "presentation"}
  ]
}
```

上例反映当前可发布声明，而不是最终目标。只有对应播放闭环完成后，才能逐项加入 `dff`、`iso` 或普通音频匹配规则。`contentFamily: "audio"` 只告诉宿主把该格式归入统一音频列表和呈现层，不能替代每次播放时的 Provider Resolution。

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
├── 兼容旧的多文件扩展 Session
└── 不再用于宿主外部音频文件列表的日常播放

restoredSession(extensionID, stateReference)
└── 恢复 Provider、队列、当前项和播放位置
```

用户打开或拖入的一组普通/高级外部音频，首先形成宿主 `FileListState`，每次只把当前项作为 `singleFile` 请求交给 Resolver。SACD ISO 中的多个 Track 也不扩展成 `fileCollection`；它们没有独立安全范围资源，属于 `singleFile(iso)` 建立后的容器内部队列。

### 6.2 Session 状态

```text
HiFiSessionState
├── sessionID
├── currentSourceResource
├── containerItems[]?       # 仅 SACD 等虚拟 Track
│   ├── stableID
│   ├── sourceReference
│   ├── containerTrackReference?
│   ├── title / artist / album / duration
│   └── playable / failure state
├── currentItemID
├── playbackPosition / playbackState
├── containerRepeatMode / shuffleMode?
├── selectedOutputDeviceID?
├── outputPolicy
└── currentOutputStatus
```

Core 只保存有 namespace、schema version 和大小限制的序列化状态引用。外部文件列表顺序、当前 ID 和播放模式由宿主窗口状态持久化；插件恢复时重新解析当前资源书签，并在 SACD 场景重新验证 Track 映射。不能持久化裸指针、sector offset 或进程相关句柄。

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

Core 负责收集资源、分类、去重、创建书签并构造唯一的 `FileListState(kind: .audio)`：

- 普通音频和扩展声明 `contentFamily: audio` 的文件可混合追加；
- activate、remove、move、上一项/下一项、播完续播、循环和随机全部作用于宿主列表；
- 当前项、时长 badge、选中状态和播放动态图标由宿主更新；
- activate 后 Resolver 对当前 URL 重新选择解码 Provider；
- Hi-Fi Session 只持有当前 DSD 文件的授权和播放状态，关闭时必须停止 HAL 并释放设备。

这样主题/UI 与扩展保持模块化：宿主拥有所有与格式无关的交互，Hi-Fi 只拥有格式、传输和设备专属能力。

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

现有 `FileListState` 和 `FileListItem` 是所有外部文件音频（Built-in 与 Hi-Fi）的宿主模型，也已支持 CUE 分段。Hi-Fi 不直接依赖这些 Core 内部 Swift 类型作为跨 Release ABI。

```text
Host FileListState（普通音频 + DSD 外部文件）→ Navigator Host → 同一套列表 UI
Hi-Fi SACD Track contribution（未来）───────→ Navigator Host → 同一套列表 UI
```

SACD 不能直接复用外部文件 URL 模型。应增加 versioned 虚拟媒体项 contract 并保持旧 Session 可解码，而不是把 `FileListCueInfo` 扩展成 SACD 专用数据结构。

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
             Hi-Fi Runtime / Engine Service
              ┌─────────────┴─────────────┐
              │ HiFiSessionController     │
              │ Current source / Track set│
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

高级解析器、DST decoder 和第三方 native code 处理不受信文件，长期仍应评估独立 Engine Service。当前 `0.1.0` 为进程内动态 Runtime，但通过 `FoofoilExtensionKit` 的 C ABI 与 JSON 值消息隔离对象边界；实时输出必须有单一所有者：

```text
Hi-Fi Runtime（当前 in-process；未来可迁移 Engine Service）
├── 文件读取与解码 worker
├── bounded ring buffer
├── CoreAudio HAL device ownership
└── realtime callback

foofoil Core
└── 只收发控制命令与低频状态，不搬运实时音频帧
```

不通过普通 XPC 消息逐 buffer 把 DoP 或高采样率 PCM 送回 Core，因为 IPC jitter、复制和背压会破坏实时性。Hi-Fi Runtime 拥有从 decoder 到 HAL 的完整链路。

当前进程内 Phase 0 已验证动态插件、文件授权、HAL/DoP 与会话命令链路。迁移 Engine Service 前仍必须验证：

- 扩展服务能否可靠枚举和打开 CoreAudio 设备；
- 安全范围文件授权能否在服务中正确建立和回收；
- Hog Mode 与设备属性恢复是否能跨服务异常退出保持安全；
- 服务崩溃后 Core 能否显示失败并重新建立 Session；
- 签名、sandbox/entitlement 和发布结构是否符合扩展系统约束。

第一版已经选择进程内运行以先闭合真实硬件链路。不得让该实现反向污染宿主：Core 仍只依赖可序列化 contract，不持有 decoder、文件句柄或 HAL 对象，为后续服务迁移保留路径。

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

SACD 容器 Track 可在下一项前提前 prepare。外部文件列表当前按项目关闭旧 Session、释放 HAL/Hog/设备格式，再路由并启动下一 Provider；尚不承诺跨 Provider gapless。未来相邻项目的 sample rate、channel layout、Provider 和输出模式一致时，可在不改变宿主列表所有权的前提下增加受控链路复用。

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

当前 Runtime 内只有一个进程级 `HALDSFPlaybackEngine`，通过 `playingSessionID` 仲裁多个窗口会话；同一时刻只能有一个会话拥有独占输出。切换或关闭会话时显式 stop、销毁 IOProc、恢复 physical/virtual format 并释放 Hog Mode。宿主在启动新的原生/扩展播放器前等待 `hifi.close` 完成，避免 DAC 尚未释放时抢先播放。迁移服务后仍保持相同语义。

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
- 当前外部文件的 `singleFile`、兼容 `fileCollection`、restored session；
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
→ Hi-Fi in-process Runtime（稳定 C ABI / JSON 边界）
→ Stereo raw DSF
→ DSFRawStream / DoP timeline
→ CoreAudio HAL / DoP DAC
→ Session 状态回传
```

同时验证宿主统一音频列表：普通音频和 DSF 使用同一 `FileListState` / `NavigatorContribution`，每次选择后再路由解码器。Runtime 的旧 `fileCollection` 队列保留兼容，但不是外部文件列表的主路径。

截至 2026-09-04 的验收结果：

1. Provider 可由 Debug bundle 装载、匹配 `.dsf` 并建立 Session；
2. 进程内 Runtime 的文件授权、HAL 访问和 C ABI 消息链路成立；
3. Stereo raw DSF 可稳定读取、播放、暂停和 Seek；
4. 参考 DAC 已正确识别并播放 DSD64；DSD256 也已通过真实硬件验证，DSD128 尚待回归；
5. 普通音频与 DSF 的统一列表、拖拽排序、动态图标、键盘/媒体键和播放模式已成立；
6. 封面、metadata 外壳、播放控件和技术信息复用宿主 UI，没有插件自定义列表；
7. 关闭 Session 会恢复设备格式并释放 Hog Mode；切换 Provider 前宿主等待释放完成；
8. DST、PCM fallback、Engine Service 与正式 Release 安装仍属后续工作；
9. raw DFF 已接通 DoP/HAL：立体声 DFF DSD64 已在 SMSL 上验收；5.0 DFF 按设备格式走 5ch / 5.1 / 7.1 或立体声折混；
10. 设备断开/占用/Hog/睡眠恢复已通过真实 DAC 手测；
11. 未压缩立体声 SACD ISO（3-in-14）已接通 sniff、CUE 式宿主列表、Seek 与 DoP 出流，并在 SMSL 上对 Wand 贝多芬 ISO 确认出声；自然结束后自动续播下一曲也已通过连续两曲实听；DST / 多声道仍未做；
12. 5.0/5.1/7.1 DoP 输出因暂无环绕 DoP DAC，真实硬件验收暂缓。

### Phase 1：DSF / DFF 可发布版本

在现有 DSF/DoP 闭环上完成 DSD128 回归、raw DFF Reader、DST、PCM fallback、设备变化恢复、DSF/DFF 专项 metadata、Session 恢复、设置、本地化和正式插件安装。DSD256 与设备变化恢复已经通过真实硬件验收。外部多文件顺序继续由宿主列表负责，不在 Hi-Fi 内重建一套队列。

验收：用户双击、拖入或批量打开 DSF/DFF 时，行为与 foofoil 其他内容一致；列表、菜单和快捷键使用宿主能力；未安装插件时能从应用内安装并继续打开。

### Phase 2：SACD ISO

Stereo Area 未压缩 3-in-14/3-in-16 已接通：sniff、Track 枚举、宿主 CUE 式列表、曲目 Seek、同一 Session 内切歌。仍缺 DST 流、gapless 精修、多声道与 Session 恢复。

验收（未压缩立体声已达到）：一个 ISO 建立一个 Session，所有 Track 在现有列表中可导航；不生成临时 DSF，不把 Track 伪装成多个外部文件，也不接管普通非 SACD ISO。

### Phase 3：增强能力

按实际需求评估 Multichannel、APE/WavPack、可视化、更高质量滤波和 Native DSD。每项独立评估体积、实时性、宿主 contract 与新 capability，不能因同属 Hi-Fi 自动扩大范围。

---

## 19. 第一版技术决策

| 项目 | 决策 |
|---|---|
| 产品形态 | 第一方可选 Hi-Fi 插件 |
| Core 体积 | 不携带高级 codec/parser/HAL 实现 |
| 普通音频 | 当前由 Built-in 播放；未来可按偏好由 Hi-Fi override |
| DSF / DFF | Phase 1 |
| DFF DST | 与 DFF 同阶段，复用到 SACD |
| SACD ISO | Phase 2，先 Stereo Area |
| `.iso` 匹配 | 必须 content sniffing |
| SACD Track | 同一资源/Session 内的逻辑队列项 |
| 外部音频列表 UI/语义 | foofoil `FileListState` + Navigator Host，混合普通音频与扩展音频 |
| 外部项目解码 | activate 后按 URL 重新执行 Provider Resolution |
| SACD Track 语义 | Hi-Fi 维护，使用 versioned 虚拟媒体项 / `media.playback-queue` |
| SACD Track 列表数据 | versioned `ui.navigator` contribution |
| 插件 UI | 不自绘播放列表；命令和状态由宿主呈现 |
| DSD 输出 | DoP 优先 |
| DoP 输出 | 当前 Hi-Fi in-process Runtime 内 CoreAudio HAL；保留迁移 Service 的协议边界 |
| DoP 不可用 | 自动 DSD → PCM |
| Exclusive | DoP 时尽量 Hog Mode，失败可降级 |
| ISO 播放 | 流式，不生成临时 DSF |
| Native DSD | 第一版不做 |
| 依赖 | 只放入 Hi-Fi，重新评估许可证与裁剪成本 |
| 音乐曲库 | 不做 |

---

## 20. 关键风险

### 20.1 扩展服务与 HAL 的部署可行性

当前进程内 Runtime 已绕开独立服务部署阻断并完成真实播放。签名、sandbox、entitlement、XPC 生命周期和安全范围授权仍可能限制未来 Engine Service 直接管理设备，因此服务迁移必须单独做部署与异常恢复 Spike，不能作为已经完成的能力描述。

### 20.2 CoreAudio 不自动等于 bit-perfect

必须实测 physical format、SRC/mixer 绕过、Hog Mode、buffer layout 和 DoP marker。设备规格不能替代运行时验证。

### 20.3 列表复用不等于复用文件路径模型

把 SACD Track 塞入 `FileListItem.path` 会导致重复 URL、错误书签、历史恢复歧义和容器 Seek 泄漏。应复用 Navigator Host，让 Track 保持插件内部逻辑 ID。

### 20.4 多窗口与独占设备冲突

播放 Session 属于窗口，物理设备独占属于应用范围。当前由进程级单例引擎仲裁；迁移服务后由 application-scope audio service 接管。不能让每个窗口各自创建不受协调的 HAL 引擎并独立取得 Hog Mode。

### 20.5 软件音量与 DoP 冲突

UI 从第一版接受 DoP 的 Fixed Volume 状态，不能为了保留滑块破坏 bitstream。

### 20.6 插件升级与恢复兼容

Hi-Fi 与 foofoil 独立发版。队列、Track ID 和设置状态需要 schema version、迁移和损坏回退；旧 Session 不能依赖 decoder 私有二进制布局。

### 20.7 通用音频输出设备选择（首版已实现，部分实机通过）

该能力属于 Hi-Fi 扩展，但服务范围是整个应用而不是单个 DSD Session。`extension-kit` 在 ABI v1 结构末尾追加可选 application command，并以 `struct_size` 保持旧 runtime 前缀兼容。Hi-Fi 枚举 CoreAudio 设备、持有 PCM Hog/格式 lease、保存所选 UID；foofoil 的普通 PCM 播放器只负责将 `AVAudioEngine` output AudioUnit 路由到 Hi-Fi 已准备的设备。

- 未安装 Hi-Fi：普通 PCM 维持系统默认输出，界面不出现设备菜单；
- 安装 Hi-Fi：PCM 可选「跟随系统默认」或其它可独占设备；选择独占设备时，Hi-Fi 优先将 nominal/physical format 调到音源采样率，设备不支持时保留可用 rate，由 `AVAudioEngine` 做 SRC，并在状态中显示 source → active rate；
- DSD：仍自动选择支持当前 DSD rate 的设备并独占，也可从右上角菜单切换到其它兼容设备；菜单显示全部设备，但以 runtime 的设备命令状态禁用不支持当前 DSD rate 或已断开的设备，不能依赖宿主元数据推测；
- 多窗口：PCM lease 与 DSD HAL 互斥，宿主在新箔接管前停止旧 PCM 输出，Hi-Fi 以 client ID 防止旧箔释放新 lease；
- 退出独占时恢复原 nominal/physical/virtual format 并释放 Hog Mode。

自动化已覆盖契约向后解码、ABI 编译、设备 rate 枚举和三仓构建。普通 PCM 单曲已实测可切换设备，支持设备按音源采样率工作；设备目录缓存和无变化格式跳过已缩短切换等待，旧分段回调失效后也已实测可从切换位置续播。仍需验证系统默认跟随、44.1/48/96/192 kHz 全组合、不支持 rate 的 SRC 状态、DSD 禁用项呈现，以及拔出/睡眠/多窗口争用恢复。

---

## 21. 建议下一步

Phase 0 的 DSF/DoP 与统一列表 Spike 已打通。raw DFF 立体声、DSD256、设备断开/占用/Hog/睡眠恢复均已通过真实硬件验收；未压缩立体声 SACD ISO 已在 SMSL 上出声，曲目自然续播也已通过连续两曲实听。5.0 输出随 DAC 能力选择，但因暂无环绕 DoP DAC，真实多声道验收暂缓。下一步按风险排序：

1. 用真实 DAC 验收第 20.7 节的通用输出设备选择与 PCM 采样率跟随；
2. 实现 DSD → PCM fallback 与 Automatic / Prefer DoP / Always PCM 策略；
3. 完成 DSD128 硬件回归；有环绕 DoP DAC 后再回归 5.0/5.1/7.1；
4. 再加入 DST、SACD 多声道、专项 metadata、Session 恢复和正式发布流程。

---

## 22. 参考

- foofoil 扩展系统实施方案：`../../foofoil/foofoil/docs/foofoil_Extension_System_Implementation_Plan.md`
- SFBAudioEngine：https://github.com/sbooth/SFBAudioEngine
- sacd_extract / sacd-ripper：https://github.com/jmmaloney4/sacd-extract
- Apple Core Audio / Audio Hardware Services 文档

参考实现只用于技术评估，不代表已完成许可证、安全、体积或维护成本审批。
