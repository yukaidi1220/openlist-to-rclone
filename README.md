# OpenList to Rclone

基于 GitHub Actions 的自动化工具集，通过 OpenList API 和 rclone 实现云端文件的批量下载、推送与驱动 ISO 制作。

## 功能一览

| 功能 | 工作流 | 状态 |
|------|--------|------|
| OpenList 文件批量下载并推送到 rclone 云端 | `openlist-download.yml` | ✅ 已完成 |
| 驱动总裁 ISO 镜像自动重打包 | `iso-repack.yml` | ✅ 已完成 |
| 自动构建 oslist | — | 🚧 TODO |
| rclone 与 OpenList 间文件双向同步 | — | 🚧 TODO |

## 已实现功能

### 1. OpenList 文件下载与推送

从 OpenList（AList 兼容接口）递归下载指定目录下的所有文件，通过 rclone 推送到目标云存储。

**流程：**

```
OpenList 目录 → 递归列出文件 → 按大小分流 → aria2c 多线程下载 → rclone 推送到云端
```

**特性：**

- 通过 OpenList API 递归扫描目录，自动获取全部文件列表
- 按 500MB 阈值自动分流：
  - **小文件（≤500MB）**：单个 Runner 批量下载后统一推送
  - **大文件（>500MB）**：每个文件独立 Runner 并行处理，最多 20 个并行
- 使用 aria2c 多线程高速下载（16/32 并发连接）
- rclone 推送时自动检测并处理远程文件/目录名冲突
- 下载失败时自动跳过，继续推送已下载的文件

**触发方式：** 手动触发（workflow_dispatch），需提供以下参数：

| 参数 | 说明 | 示例 |
|------|------|------|
| `openlist_domain` | OpenList 域名（不含 https://） | `files.example.com` |
| `source_path` | 源目录路径 | `/path/to/files` |
| `remote_path` | rclone 推送目标 | `mupan:\Some\Folder` |

### 2. 驱动总裁 ISO 重打包

自动从云端拉取驱动总裁 ISO 镜像，替换其中的驱动包为最新版本，重新打包上传。

**流程：**

```
rclone 下载 ISO → 7z 解压 → 提取关键目录（PESRS/Win7/Win10 等）
→ 下载最新驱动包 ZIP → 覆盖解压 → IMAPI2 重新打包 ISO → 上传 + MD5 校验
```

**特性：**

- 自动识别驱动包目录中版本号最高的 ZIP 文件
- 支持 ISO 和 ZIP 的 MD5 校验（有 `.md5` 文件时自动校验）
- 提取 6 个目标目录：`PESRS`、`Win7x64`、`Win7x86`、`Win10x64`、`Win10x86`、`WinXPx86`
- 使用 IMAPI2 COM 接口创建 ISO（ISO9660 + Joliet + UDF）
- 多 ISO 并行处理，最多 10 个同时运行
- 磁盘空间预检查（预估 5 倍 ISO 大小）
- 自动生成并上传 `.md5` 校验文件

**触发方式：** 手动触发（workflow_dispatch），需提供以下参数：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `source_path` | rclone 源路径（ISO 所在目录） | `mupan:/File/DrvCeo_XR` |
| `target_path` | rclone 目标路径（上传目录） | `mupan:/File/DrvCeo` |
| `drvzip_path` | 驱动包 ZIP 所在目录 | `mupan:/File/DrvCeo_Main` |

## TODO

- [ ] **自动构建 oslist** — 自动化构建 oslist
- [ ] **rclone ↔ OpenList 文件同步** — 实现双向或单向的增量文件同步

## 仓库依赖

- **rclone 配置**：通过 `RCLONE_PAT` 从同 Owner 下的 `rclone-action` 仓库获取 `rclone.conf`
- **运行环境**：GitHub Actions `windows-latest`（预装 7-Zip）
- **下载工具**：aria2c（从 Motrix 项目获取）
