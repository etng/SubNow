# SubNow

SubNow 是一个菜单栏字幕工具。你在 mpv 或 IINA 里播放没有中文字幕的视频时，它会提醒你；确认后在本机转录、翻译，并把字幕挂到播放器里。

## 安装

```bash
brew install --cask etng/taps/subnow
```

需要 Apple Silicon 和 macOS 14 或更高版本。首次启动会引导下载语音识别模型。

安装包为 ad-hoc 签名，brew 会自动移除隔离标记。手动下载 DMG 若被 Gatekeeper 拦截，执行：

```bash
xattr -dr com.apple.quarantine /Applications/SubNow.app
```

## 使用

1. 用 mpv 或 IINA 播放视频。
2. 收到「没有中文字幕」的通知后，点「生成字幕」。
3. 菜单栏显示任务进度。先出原文和双语粗稿，精做版完成后自动替换。

也可以从菜单栏手动选择「为这个视频生成字幕」。某个视频不想再被提醒，点「忽略本次」。

## 播放器设置

IINA 默认不开放 mpv 的 IPC 接口。配置后可以精确判断字幕轨，并在播放过程中直接挂载字幕：

IINA → 设置 → 高级 → 启用高级设置 → 额外 mpv 选项，填入：

```
input-ipc-server=/tmp/subnow-mpv.sock
```

然后完全退出并重新打开 IINA。

不配置也能用：字幕会生成在视频旁边，下次播放时自动加载。

CLI mpv 在 `~/.config/mpv/mpv.conf` 中加入同一行。

## 翻译

设置 → 翻译 中可选：

- Ollama：本地运行，默认选项
- OpenAI 兼容 API：填写 Base URL、Key 和模型名
- Apple 系统模型：macOS 26+，需要 Apple Intelligence
- 不翻译：只输出原文

## 文件与隐私

转录和本地翻译都在本机完成。使用 OpenAI 兼容 API 时，字幕文本会发送到你配置的服务。

配置、模型和日志位于：

```
~/Library/Application Support/SubNow
~/Library/Logs/SubNow.log
```

生成的字幕写在视频同目录，与视频同名，播放器会自动加载。

## 卸载

```bash
brew uninstall --cask --zap subnow
```

## 开发

构建、发布和维护文档在单独的私有仓库，不随应用仓库公开。
