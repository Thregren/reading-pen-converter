# 点读包转换

一个在 macOS 和 Windows 上离线转换 **🐛 BNL** 和 **小时候的🐸 BNF** 点读包的工具。把点读包拖进 App，选个保存位置，就能生成另一种格式的音频版点读包。

**当前支持经过验证的 BNF v11 和 BNL 模式 2 样本。** 两个方向都完成了桌面转换与文件回读验证。生成的文件能否在目标笔上直接点原书，仍待实机确认。

## macOS 快速开始

需要 **macOS 14 或更新版本**。App 是通用二进制，适用于 Apple 芯片（arm64）和 64 位 Intel（x86_64）Mac。从 [GitHub Releases](https://github.com/Thregren/reading-pen-converter/releases/latest) 下载 `ReadingPenConverter-macOS-universal.zip`，解压后打开「点读包转换」。当前构建使用本地临时签名，尚未经过 Apple 公证。

1. 从 Finder 拖入一个或多个 `.bnf` 或 `.bnl` 文件，也可以点击“选择点读包”。
2. App 自动识别格式和转换方向，使用内置的模板和 BNL 编解码组件，弹出保存窗口。
3. 选一个 Mac 本地的保存位置。完成后点击“在 Finder 中查看”，即可找到新点读包和同目录的 `.conversion.json` 报告。

![BNF 转换为 BNL 后的完成界面](output/finder-drop-check/renamed/01-完成.png)

## Windows 快速开始

从 [GitHub Releases](https://github.com/Thregren/reading-pen-converter/releases/latest) 选择 x64（Intel、AMD）或 ARM64 便携版 ZIP，完整解压后双击 `ReadingPenConverter.exe`。把一个或多个 `.bnf` 或 `.bnl` 文件从文件资源管理器拖进窗口，选择保存位置。完成后可以直接打开输出文件夹。ZIP 内含运行库和目标模板。

转换在本机完成，原始文件保持原样。App 会检查输出目录里同格式包的注册范围，发现冲突时会提示。笔内已有包、其他目录和设备缓存需要另行核对。

## 批量转换

一次选择或拖入多个点读包，再选一次输出文件夹。BNF 和 BNL 可以混选，App 会逐个转换，并为每个成功的点读包保存一份转换报告。遇到同名包或报告时，App 会给新文件加上编号。遇到点读码冲突或无法读取的书时，会列出失败原因并继续处理其余文件。

BNL 转 BNF 时，如果遇到截断的 MP3，App 会在同一本书的完整录音中查找相同的字节，并按 MP3 帧边界恢复片段。转换报告会记录修复的录音、来源和受影响的点读码。找不到可靠匹配时，App 会提示媒体编号和引用它的点读码。

## 转换会保留什么？

App 从源包读取数值点读码、播放列表和 MP3 音频，按原数值点读码重建目标格式的索引和音频，然后回读新包核对对应关系。

- **保留**有效音频点的原数值点读码及对应音频。当前使用固定的目标模板，输出新包会继承模板的部分身份字段。
- **简化**已识别的系统控制和部分非音频事件。BNF 转 BNL 时，轮换或随机播放会变成固定列表。转换报告会记录相关变化，遇到超出支持范围的命令，转换会报错。
- **实机待测**。同一纸面位置必须在目标笔上产生可命中新包的编号，才能播出对应音频。目前还没有两支笔点同一位置的读数，App 按原码写出。

| 样本 | 方向 | 文件级验证 |
| --- | --- | --- |
| 《GoGo 默认卡－儿歌》 | BNF → BNL | 原有的 1 个有效音频码保持一致 |
| 《Who Did That》 | BNL → BNF | 原有的 99 个有效音频码逐个一致 |

[逐码复核结果](research/paper-route-review.json) · [原书实机核验表](research/paper-tap-check.md)

## 从源码构建

需要 Swift 6 工具链和 Python 3。打包脚本使用工作区里的两个模板样本。BNL 编解码组件内置两张各 256 字节的兼容表，构建和转换都无需原始固件。需要提取固件系统音频时，可单独传入固件文件。

```sh
./scripts/build.sh
swift test
```

构建脚本会为两种架构编译并合并 App 和命令行工具。构建后，可从 `dist/` 打开 App 或运行命令行工具。直接运行 `./dist/penconvert` 可查看命令列表，其中包括包检查、目录扫描、音频提取和 BNL 重封包。

在 Windows 上构建时，使用与目标架构一致的 Swift 工具链、Visual Studio C++ 工具和 .NET 10 SDK。打包脚本默认输出到 `dist/windows/`。

```powershell
./scripts/build-windows.ps1 -TemplateBnf 'C:\templates\target.bnf' -TemplateBnl 'C:\templates\target.bnl'
```

| 路径 | 用途 |
| --- | --- |
| [Sources/PenMac](Sources/PenMac) | SwiftUI 界面、Finder 拖放与保存流程 |
| [Windows](Windows) | Windows Forms 界面、文件资源管理器拖放与保存流程 |
| [Sources/PenCore](Sources/PenCore) | 格式解析、转换、回读校验和码段冲突检查 |
| [Sources/PenCLI](Sources/PenCLI) | 命令行入口 |
| [Tests/PenCoreTests](Tests/PenCoreTests) | 解析、写出和冲突检查测试 |

[研究过程与进阶用法存档](research/project-history.md)
