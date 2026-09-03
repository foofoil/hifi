# Hi-Fi for foofoil

面向 [foofoil](https://github.com/foofoil/foofoil) 的高保真本地音频扩展。**需要先安装 foofoil。**

Hi-Fi 是 foofoil 的第一方扩展，不能作为独立播放器运行。请先安装 foofoil，再在应用内安装 Hi-Fi（或在从源码构建时加载开发用扩展包）。

它为轻量 Core 补充高解析度与 DSD 播放：DSF/DFF、SACD ISO/DST（进行中）、增强系统已能播放的格式、输出设备选择、DoP，以及音乐场景下的会话能力。播放列表由 foofoil 的通用导航面板呈现，扩展不提供私有侧栏。

[English](README.md)

## 当前状态

当前代码是从 foofoil `hifi-ext` 功能分支抽出的 Phase 0 开发样机：

- DSF / raw DFF → DoP → CoreAudio HAL → USB DAC
- Stereo DSD64 DSF 与立体声 DFF 已在 SMSL DAC 上验收；5.0 DFF 按设备能力输出环绕或折成立体声
- 宿主侧具备播放、暂停、进度轮询、输出设备选择和关闭时释放设备的能力

这还不是正式发布。尚未完成的工作包括 DSD → PCM fallback、DST / SACD ISO、专项 metadata、Session 恢复、DSD128/256 硬件回归、进程隔离，以及可供应用内安装的签名与公证 GitHub Release。设备断开/占用/睡眠恢复已实现，待真实 DAC 手测。

详见 [docs/hifi-phase0-dsf-playback-handoff.md](docs/hifi-phase0-dsf-playback-handoff.md) 和 [docs/foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md](docs/foofoil_DSF_DFF_SACD_ISO_Technical_Plan_v2.md)。

## 系统要求

- [foofoil](https://github.com/foofoil/foofoil)（宿主应用）
- macOS 15 或更高版本，Apple 芯片
- 从源码构建需要 Xcode / Swift 6

兼容的 Extension API：v1（见 `ExtensionManifest.json` 中的 `extensionAPI.min` / `max`）。

## 本地播放验收

Hi-Fi 尚未进入应用内 Registry。要在真实设备上试播，请把 `hifi` 放在 `foofoil` 的兄弟目录，并用宿主仓库的 `./run` 启动：它会构建本包，并把 `Hi-Fi.foofoilextension` 注入 Debug 应用。

```sh
cd ../foofoil
./run
```

然后将 Stereo DSD64 的 `.dsf` 拖到箔片上，或用“文件 → 打开”。窗口内可播放/暂停，菜单栏“扩展”里可选择输出设备。不要用 Xcode 的 ⌘R 做这条路径，它不会注入插件。

只打扩展包：

```sh
./build-plugin /tmp/foofoil-hifi-plugin
```

将生成 `Hi-Fi.foofoilextension`。正式安装仍走 foofoil 的 Extension Manager，不会打进 `foofoil.app`。

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
