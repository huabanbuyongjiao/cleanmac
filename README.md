# cleanmac

`cleanmac` 是 macOS 只读存储扫描器。它用中文列出扫描项目的路径、大小、类别、风险和说明，方便你先检查，再自行决定是否处理。

扫描器不会删除、移动或修改扫描范围内的内容，也没有清理命令。它只会在报告输出目录新建 Markdown 和 CSV 报告；如果报告文件已存在，会停止以避免覆盖。

## 快速开始

1. 在终端进入仓库目录。
2. 赋予脚本执行权限：

   ```bash
   chmod +x cleanmac.sh
   ```

3. 运行扫描并指定一个新的报告目录：

   ```bash
   ./cleanmac.sh --output-dir ./cleanmac-report
   ```

4. 打开 `cleanmac-report/cleanmac-scan-report.md` 阅读中文报告，也可用表格软件打开 CSV。

不指定 `--output-dir` 时，报告会生成在当前目录。为避免覆盖，两个同名报告中任意一个已存在时，扫描器都会停止。

## 扫描内容

| 类别 | 路径或规则 | 风险 | 说明 |
|---|---|---|---|
| 用户缓存 | `~/Library/Caches` 下的应用目录 | 低 | 缓存通常可以重建；Google Chrome 缓存单独列出，避免重复计数 |
| 应用日志 | `~/Library/Logs` 下的项目 | 中 | 日志可能用于排查问题 |
| Chrome 浏览器缓存 | Chrome 缓存目录，包括 `Cache`、`Cache_Data`、`Code Cache`、`GPUCache` | 低 | 不清理浏览历史、Cookie 或个人资料 |
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData` | 低 | 构建产物可以重新生成；正在构建时应先检查 |
| 废纸篓 | `~/.Trash` | 高 | 可能含有需要恢复的个人文件 |
| 下载文件 | `~/Downloads` 中超过 90 天未修改的文件，或超过大文件阈值的文件 | 高 | 可能仍有个人用途，请逐项核对 |
| 大文件 | 用户主目录内超过大文件阈值的文件 | 高 | 仅报告，不会处理；下载、缓存、日志、废纸篓、Chrome 资料目录及 Xcode DerivedData 会在此项中排除，避免重复或扫描应用数据 |

Docker 相关路径会排除。大文件扫描不会深入 `.epub`、照片图库、应用程序和其他 macOS 资料包目录，避免把资料包内部内容误列成独立文件。每项按风险从低到高排序；同一风险内按大小从大到小排序。目录大小使用 `du` 估算，单个文件大小读取文件元数据。macOS 拒绝读取的路径会跳过并在终端显示；报告只汇总实际可读到的项目。

## 参数

```text
--output-dir DIR  报告输出目录（默认当前目录）
--large-mb N      大文件阈值，单位 MB（默认 500）
--old-days N      下载文件的旧文件天数（默认 90）
--help            显示帮助
```

例如，把旧下载阈值设为 180 天、大文件阈值设为 1,000 MB：

```bash
./cleanmac.sh --old-days 180 --large-mb 1000 --output-dir ./cleanmac-report
```

## 安全规则

- 扫描器只读扫描，不包含删除、清理、移动或重置功能。
- 用户缓存、Chrome 缓存和 DerivedData 标为低风险；日志标为中风险；废纸篓和个人文件标为高风险。
- 报告中的大小表示找到的项目占用或文件大小，不代表可以不经检查安全删除。
- 扫描器不会使用 `sudo`，也不会执行 Homebrew、Docker、模拟器或 QuickLook 清理命令。
