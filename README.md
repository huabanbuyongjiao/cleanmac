# cleanmac

安全清理 macOS 存储空间的命令行工具。单文件 Bash 脚本,无任何依赖,兼容 macOS 自带的 bash 3.2。

## 特性

- **默认预览模式(dry-run)**:直接运行只统计各类别可释放的空间,不删除任何文件
- **逐类确认**:真正清理时,每个类别先显示占用大小,确认后才删除
- **只清理公认安全的内容**:缓存、日志、构建产物等可再生文件;个人文件只报告大小,绝不删除
- **清空目录内容而非删除目录**:避免破坏应用对缓存目录的引用

## 使用

```bash
chmod +x cleanmac.sh

# 预览:统计所有类别可释放的空间(不删除任何文件)
./cleanmac.sh

# 交互式清理所有类别(逐类确认)
./cleanmac.sh --clean

# 跳过确认,清理指定类别
./cleanmac.sh --clean -y xcode brew npm

# 查看所有支持的类别
./cleanmac.sh --list
```

## 清理类别

| 类别 | 内容 | 说明 |
|------|------|------|
| `caches` | `~/Library/Caches` | 应用缓存,删除后应用会自动重建 |
| `logs` | `~/Library/Logs` | 用户日志文件 |
| `trash` | `~/.Trash` | 废纸篓 |
| `xcode` | DerivedData、Archives、iOS DeviceSupport | 构建产物与旧设备符号;Archives 含 dSYM,删除前注意 |
| `simulators` | `xcrun simctl delete unavailable` | 删除不可用的 iOS 模拟器 |
| `brew` | `brew cleanup --prune=all -s` | Homebrew 旧版本与下载缓存 |
| `npm` | npm / yarn / pnpm 缓存 | 包管理器缓存 |
| `pip` | pip 缓存 | Python 包缓存 |
| `docker` | `docker system prune -f` | 悬空镜像、停止的容器、构建缓存 |
| `saved-state` | `~/Library/Saved Application State` | 应用窗口恢复状态 |
| `quicklook` | `qlmanage -r cache` | QuickLook 缩略图缓存 |

此外,预览模式会列出 `~/Downloads`、`~/Documents`、`~/Desktop`、`~/Movies` 中大于 500MB 的文件 Top 15,**仅供参考,不会删除**。

## 安全说明

- 不会触碰系统级目录(`/Library`、`/System`),无需 `sudo`
- 不会删除任何文档、照片、下载等个人文件
- `xcode` 类别中的 Archives 包含 App Store 提交记录与 dSYM 符号文件,如果你需要符号化历史版本的崩溃日志,清理时请选择跳过该项
