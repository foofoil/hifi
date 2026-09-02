# Hi-Fi for foofoil

面向 [foofoil](https://github.com/foofoil/foofoil) 的高保真本地音频扩展。**需要先安装 foofoil。**

Hi-Fi 是 foofoil 的第一方扩展，不能作为独立播放器运行。请先安装 foofoil，再在应用内安装 Hi-Fi（或在从源码构建时加载开发用扩展包）。

它为轻量 Core 补充高解析度与 DSD 播放：DSF/DFF、SACD ISO/DST（进行中）、增强系统已能播放的格式、输出设备选择、DoP，以及音乐场景下的会话能力。播放列表由 foofoil 的通用导航面板呈现，扩展不提供私有侧栏。

[English](README.md)

## 当前状态

当前代码是从 foofoil `hifi-ext` 功能分支抽出的 Phase 0 开发样机：

- DSF raw DSD → DoP → CoreAudio HAL → USB DAC
- 已在 Stereo DSD64 设备上完成播放验收
- 宿主侧具备播放、暂停、进度轮询、输出设备选择和关闭时释放设备的能力

这还不是正式发布。尚未完成的工作包括 DSD → PCM fallback、raw DFF / DST / SACD ISO、完整 seek、播放队列与 Navigator 闭环、metadata 与封面、Session 恢复、更多 DSD 速率、进程隔离，以及可供应用内安装的签名与公证 GitHub Release。

详见 [docs/hifi-phase0-dsf-playback-handoff.md](docs/hifi-phase0-dsf-playback-handoff.md) 和 [docs/foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md](docs/foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md)。

## 系统要求

- [foofoil](https://github.com/foofoil/foofoil)（宿主应用）
- macOS 15 或更高版本，Apple 芯片
- 从源码构建需要 Xcode / Swift 6

兼容的 Extension API：v1（见 `ExtensionManifest.json` 中的 `extensionAPI.min` / `max`）。

## 构建开发用扩展包

```sh
chmod +x build-plugin
./build-plugin /tmp/foofoil-hifi-plugin
```

将生成 `Hi-Fi.foofoilextension`。开发阶段可在宿主 Debug 构建后复制到 foofoil 的 `Contents/PlugIns`。正式安装走 foofoil 的 Extension Manager，不会打进 `foofoil.app`。

## 测试与工具

```sh
swift test
swift run hifi-inspect --help
swift run hifi-hal-probe
```

`HiFiExtensionRuntime` 导出 `foofoil_extension_create`，与宿主交换 JSON 值消息，不导入 SwiftUI，也不把进程内 View 传入 ABI。

## 相关仓库

| 仓库 | 职责 |
| --- | --- |
| [foofoil](https://github.com/foofoil/foofoil) | 宿主应用，必须先安装 |
| [extension-kit](https://github.com/foofoil/extension-kit) | 扩展 API 契约、ABI 头文件和 Manifest Schema |

## 许可证

Hi-Fi 使用 [MIT License](LICENSE)，版权所有 © 2026 北京记忆视界科技有限公司。
