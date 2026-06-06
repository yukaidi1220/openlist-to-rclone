# OpenList to Rclone

基于 GitHub Actions 的自动化工具集，通过 OpenList API 和 rclone 实现云端文件的批量下载、推送与驱动 ISO 制作。

## 功能一览

| 功能 | 工作流 | 状态 |
|------|--------|------|
| OpenList 文件批量下载并推送到 rclone 云端 | `openlist-download.yml` | ✅ 已完成 |
| 驱动总裁 ISO 镜像自动重打包 | `iso-repack.yml` | ✅ 已完成 |
| URL 直接下载并上传到 rclone 云端 | `url-direct-download.yml` | ✅ 已完成 |
| rclone 多目标同步 | `rclone-sync.yml` | ✅ 已完成 |
| rclone 分批同步（大规模文件） | `rclone-batch-sync.yml` | ✅ 已完成 |
| rclone 多目标分批同步 | `rclone-multi-batch-sync.yml` | ✅ 已完成 |
| 自动构建 oslist | — | 🚧 TODO |

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
| `target_path` | rclone 目标路径（上传目录） | `mupan:/File/DrvCeo_Mod` |
| `drvzip_path` | 驱动包 ZIP 所在目录 | `mupan:/File/DrvCeo_Main` |

### 3. URL 直接下载并上传

从指定 URL 直接下载文件，支持 MD5/SHA256 校验，然后通过 rclone 上传到目标云存储。

**流程：**

```
JSON 配置 → 解析文件列表 → aria2c 多线程下载 → 文件校验 → rclone 上传到云端
```

**特性：**

- 支持批量下载，通过 JSON 文件配置多个下载任务
- 支持 IPv6（可选安装 Cloudflare WARP）
- 支持 MD5 和 SHA256 文件校验（可选）
- 自动生成并上传 `.md5` 校验文件
- 使用 aria2c 多线程高速下载（16 并发连接）
- 下载和上传阶段可切换 IP 优先级（IPv6 下载，IPv4 上传）

**触发方式：** 手动触发（workflow_dispatch），需提供以下参数：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `json_url` | JSON 文件链接 | — |
| `enable_ipv6` | 是否启用 IPv6 | `yes` |
| `rclone_path` | rclone 上传目标目录 | `mupan:/File/Origin_System` |

**JSON 格式：**

```json
[
  {
    "url": "https://example.com/file1.iso",
    "filename": "file1.iso",
    "md5": "d41d8cd98f00b204e9800998ecf8427e",
    "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  },
  {
    "url": "https://example.com/file2.zip",
    "filename": "file2.zip"
  }
]
```

### 4. rclone 多目标同步

通过 JSON 配置多个同步目标，实现 rclone 源路径到多个目标路径的并行同步。

**流程：**

```
JSON 配置 → 解析源和目标 → 矩阵并行 sync → 每个目标独立 Runner
```

**特性：**

- 支持多目标并行同步，最多 20 个并行
- 每个目标可独立配置 IPv6 优先级
- 自动部署 OpenList 服务（list: remote 依赖）
- 路径安全校验，防止注入攻击
- 支持 IPv6（通过 Cloudflare WARP）
- 自动配置 IP 版本优先级（gai.conf）

**触发方式：** 手动触发（workflow_dispatch），需提供以下参数：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `json_url` | JSON 文件链接 | 示例链接 |

**JSON 格式：**

```json
{
  "source": "mupan:File",
  "targets": [
    { "path": "list:cr/qzy-hk-mupan", "prefer_ipv6": true },
    { "path": "list:cr/qzy-cn-mupan", "prefer_ipv6": false }
  ]
}
```

> **注意**：此工作流使用 `rclone sync` 进行全量同步，适合文件数量较少的场景。大规模文件同步请使用 `rclone-multi-batch-sync.yml`。

### 5. rclone 分批同步（大规模文件）

针对大规模文件（几百 GB 到 TB 级）的同步场景，通过 bin-pack 算法将文件分批，每批 ≤ 50GB，支持矩阵并行同步，单个 batch 失败可独立重跑。

**流程：**

```
对比两端差异 → 获取文件列表 → bin-pack 分批 → 矩阵并行同步 → 可选清理目的端多余文件
```

**特性：**

- First-Fit Decreasing 算法（大文件优先），保证每批 ≤ 50GB
- 三种运行模式：完整同步、仅分批、重跑单个 batch
- 每个 batch 独立 runner 并行处理，最多 10 个并行
- 单个 batch 失败可独立重跑，不浪费已成功的
- 支持自定义每批最大大小和单文件最大大小
- 可选清理目的端多余文件（使用 `rclone sync`）
- 支持 `workflow_call`，可被其他工作流调用

**触发方式：**

1. **手动触发**（workflow_dispatch）
2. **被其他工作流调用**（workflow_call）

**手动触发参数：**

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `mode` | 运行模式 | `full` |
| `rclone_src` | 源路径 | — |
| `rclone_dst` | 目标路径 | — |
| `max_batch_gb` | 每批最大大小（GB） | `50` |
| `max_file_gb` | 单文件最大大小（GB） | `100` |
| `cleanup_dst` | 是否清理目的端多余文件 | `false` |
| `batch_id` | rerun 模式下要重跑的 batch 编号 | — |
| `run_id` | rerun 模式下原始 workflow run_id | — |

**运行模式：**

| 模式 | 作用 |
|------|------|
| `full` | 完整流程：分批 + 同步所有 batch + 可选清理 |
| `dispatch` | 只运行分批，查看结果 |
| `rerun` | 重跑指定 batch |

**使用流程：**

1. **首次运行**：选 `dispatch` 模式，看分批结果是否合理
2. **确认后**：选 `full` 模式，矩阵并行同步
3. **有失败**：记下 `run_id`，选 `rerun` 模式，输入失败的 `batch_id`

---

### 6. rclone 多目标分批同步

结合多目标和分批同步的能力，从 JSON 配置读取多个目标，每个目标独立进行分批同步。

**流程：**

```
JSON 配置 → 解析多目标 → 每个目标调用 rclone-batch-sync.yml → 矩阵并行
```

**特性：**

- 支持多目标独立配置（批量大小、文件大小限制、清理策略）
- 每个目标独立进行分批同步
- 路径安全校验，防止注入攻击
- 配置统一在 JSON 中管理

**触发方式：** 手动触发（workflow_dispatch），需提供以下参数：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `json_url` | JSON 文件链接 | 示例链接 |

**JSON 格式：**

```json
{
  "source": "mupan:File",
  "targets": [
    {
      "path": "list:cr/qzy-hk-mupan",
      "prefer_ipv6": true,
      "max_batch_gb": 50,
      "max_file_gb": 100,
      "cleanup_dst": true
    },
    {
      "path": "webdav:backup",
      "prefer_ipv6": false,
      "max_batch_gb": 30,
      "max_file_gb": 50,
      "cleanup_dst": false
    }
  ]
}
```

**JSON 字段说明：**
- `source`：rclone 源路径
- `targets`：目标路径数组
  - `path`：rclone 目标路径
  - `prefer_ipv6`：是否优先使用 IPv6
  - `max_batch_gb`：每批最大大小（GB），默认 50
  - `max_file_gb`：单文件最大大小（GB），默认 100
  - `cleanup_dst`：是否清理目的端多余文件，默认 false

## TODO

- [ ] **自动构建 oslist** — 自动化构建 oslist
- [ ] **优化分批算法** — 支持更智能的分批策略（考虑文件数量、传输时间等）

## 仓库依赖

- **rclone 配置**：通过 `RCLONE_PAT` 从同 Owner 下的 `rclone-action` 仓库获取 `rclone.conf`
- **运行环境**：
  - `windows-latest`：用于 openlist-download、iso-repack 工作流
  - `ubuntu-latest`：用于 url-direct-download、rclone-sync、rclone-batch-sync 工作流
- **下载工具**：
  - aria2c（从 Motrix 项目获取）
  - rclone（官方安装脚本）
- **网络工具**：
  - Cloudflare WARP（wgcf + WireGuard）用于 IPv6 支持
- **脚本工具**：
  - `bin/split_batches.sh`：bin-pack 分批脚本（用于 rclone-batch-sync）
- **示例文件**：
  - `examples/sync-tasks.json`：rclone 多目标同步配置示例
  - `examples/download-tasks.json`：URL 直接下载配置示例

## 示例文件说明

### sync-tasks.json

用于 `rclone-sync.yml` 和 `rclone-multi-batch-sync.yml` 工作流，配置多个同步目标：

```json
{
  "source": "mupan:File",
  "targets": [
    {
      "path": "list:cr/qzy-hk-mupan",
      "prefer_ipv6": true,
      "max_batch_gb": 50,
      "max_file_gb": 100,
      "cleanup_dst": true
    },
    {
      "path": "list:cr/qzy-cn-mupan",
      "prefer_ipv6": false,
      "max_batch_gb": 30,
      "max_file_gb": 50,
      "cleanup_dst": false
    }
  ]
}
```

**字段说明：**
- `source`：rclone 源路径
- `targets`：目标路径数组
  - `path`：rclone 目标路径
  - `prefer_ipv6`：是否优先使用 IPv6
  - `max_batch_gb`：每批最大大小（GB），默认 50（仅 `rclone-multi-batch-sync.yml` 使用）
  - `max_file_gb`：单文件最大大小（GB），默认 100（仅 `rclone-multi-batch-sync.yml` 使用）
  - `cleanup_dst`：是否清理目的端多余文件，默认 false（仅 `rclone-multi-batch-sync.yml` 使用）

### download-tasks.json

用于 `url-direct-download.yml` 工作流，配置多个下载任务：

```json
[
  {
    "url": "https://example.com/file1.iso",
    "filename": "file1.iso",
    "md5": "d41d8cd98f00b204e9800998ecf8427e",
    "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  },
  {
    "url": "https://example.com/file2.zip",
    "filename": "file2.zip",
    "md5": null,
    "sha256": null
  },
  {
    "url": "https://example.com/file3.exe",
    "filename": "file3.exe"
  }
]
```

**字段说明：**
- `url`：下载链接（必填）
- `filename`：保存文件名（必填，不能包含路径分隔符）
- `md5`：MD5 校验值（可选，支持三种写法：省略字段、`null`、具体哈希值）
- `sha256`：SHA256 校验值（可选，支持三种写法：省略字段、`null`、具体哈希值）

### split_batches.sh

用于 `rclone-batch-sync.yml` 工作流，将文件列表按大小分批：

**用法：**
```bash
bash bin/split_batches.sh files_with_size.txt [max_gb]
```

**输入：**
- `files_with_size.txt`：格式为 `字节数;路径`（由 `rclone lsf --format ps --separator ";"` 生成）
- `max_gb`：每批最大大小（GB），默认 50

**输出：**
- `batch_*.txt`：每个 batch 的文件路径列表
- stdout：matrix JSON（用于 GitHub Actions 矩阵）
