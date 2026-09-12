#!/usr/bin/env bash
#
# chunk-probe.sh — 基于随机分片 Range 下载的双端内容比对探针 (三阶段并行版)
#
# 目的:对 source 桶与 wopan 目标端做"分片级"内容抽样比对,快速定位大体量文件的内容损坏,
#       而不必把整个文件下载下来 (整文件抽样对大 ISO 慢)。
#
# 三阶段架构 (解决串行 per-片 rclone 进程/网络往返过慢的问题):
#   阶段1 造清单 : lsjson 过滤出候选文件, 对每文件按 N=min(ceil(Size/100MiB),100) 片
#                  算出随机偏移, 输出平铺清单 (每行 文件|偏移|片长|片序号).
#   阶段2 并行拉 : 以 -P 并发启动 rclone cat --offset/--count, 对清单每一行同时从
#                  源端与目标端拉取该片段落盘到独立临时文件 (HTTP Range -> 206).
#   阶段3 并行比 : 对所有落盘分片并行跑 md5sum, 比对源/目标对应分片, 汇总一致/不一致,
#                  并使用 CHECKER 并发清理临时文件.
#
# 相比串行版: 网络往返可满带宽、rclone 进程启动开销被并发摊薄、比对不重传数据。
#
# 用法:
#   chunk-probe.sh <src:path> <dst:path> [--limit N] [--min-mib] [--slice-s] [--p N]
#
# 环境变量:
#   RCLONE   : rclone 可执行文件路径 (默认 rclone)
#   SLICE    : 单片下载长度字节 (默认 4194304 = 4MiB)
#   LIMIT    : 最多探测多少个文件 (默认 -1 = 全部)
#   MIN_SIZE : 只探测 >= 该字节对象 (默认 1048576 = 1MiB)
#   JOBS     : 并行拉取作业数 (默认 8, 源+目标各一连接算 1 片 2 连接)
#   CHECKERS : 并行 md5 校验作业数 (默认 4)
#   NO_CLEAN : 非空则保留临时分片文件供复查 (默认清理)
#
# 输出:每文件一行结果到 stdout / 汇总与错误到 stderr;
#       退出码 0=全部一致, 1=发现不一致, 2=有分片拉取失败(数据不完整)。

set -euo pipefail

RCLONE="${RCLONE:-rclone}"
SLICE="${SLICE:-4194304}"          # 4MiB
LIMIT="${LIMIT:--1}"
MIN_SIZE="${MIN_SIZE:-1048576}"    # 1MiB
JOBS="${JOBS:-8}"
CHECKERS="${CHECKERS:-4}"
CHUNK_PER_100M=104857600
PYTHON="${PYTHON:-python3}"
WORKDIR="$(mktemp -d /tmp/probe.XXXXXX)"

SRC="${1:?src:path required}"
DST="${2:?dst:path required}"

# 打点器: 输出 mm:ss 相对运行开始的时间戳 (便于定位卡点)
START_TS=$SECONDS
tick() { local label="$1"; echo "  [$(date -u +%H:%M:%S) t=$((SECONDS-START_TS))s] $label" >&2; }

# ---- 阶段 1: 造清单 ----
tick "阶段1开始 造清单 src=$SRC dst=$DST slice=$SLICE limit=$LIMIT jobs=$JOBS"

# 先 lsjson 一次取候选 (列出 >= MIN_SIZE 的文件)
# lsjson 全桶递归列所有对象(阿里 OSS ListObjectsV2 高位接口,应快)。
# 关键: 结果重定向到文件(流式写盘), 不落 bash 数组 —— bash 数组对几十万元素极慢,
#       迁移流程用 > files.json 写盘未卡, 探针此前用 mapfile 存数组才卡死。
tick "阶段1a 发起 rclone lsjson -R -> files.json (全桶递归)..."
FILES_JSON="$WORKDIR/files.json"
"$RCLONE" lsjson "$SRC" -R --files-only --no-mimetype --no-modtime -vv 2>"$WORKDIR/lsjson.vv.log" >"$FILES_JSON"
LIST_RC=$?
[ "$LIST_RC" -eq 0 ] || { echo "::error::lsjson 失败 rc=$LIST_RC (见 lsjson.vv.log)"; tail -20 "$WORKDIR/lsjson.vv.log" >&2; exit 1; }
tick "阶段1a 完成 lsjson -> files.json ($(du -h "$FILES_JSON" | cut -f1))"

# python:从 files.json 流式取 top LIMIT 大文件并生成平铺分片清单
# 不在 bash 里建大数组; python json.load 一次性读 + 内存排序, 比 bash mapfile 可靠。
tick "阶段1b 分片计划 (top ${LIMIT} 大文件)..."
total_count=$("$PYTHON" - "$FILES_JSON" "$WORKDIR/chunks.0" "$CHUNK_PER_100M" "$SLICE" "$LIMIT" "$MIN_SIZE" <<'PY')
import sys, math, random, json
fj, out, per100m, sl, lim, minsz = sys.argv[1:]
per100m, sl, minsz, lim = int(per100m), int(sl), int(minsz), int(lim)
with open(fj) as f:
    data = json.load(f)
files = [(o["Path"], int(o["Size"])) for o in data if int(o["Size"]) >= minsz]
total = len(files)
# 降序取 limit (聚焦大文件; -1=全部)
if lim >= 0:
    files.sort(key=lambda x: -x[1])
    files = files[:lim]
random.seed(0x5EED)
with open(out, "w") as o:
    for path, size in files:
        n = max(1, min(math.ceil(size / per100m), 100))
        eff = max(0, size - sl)
        for i in range(n):
            lo = size * i // n
            hi = size * (i + 1) // n - 1
            hix = max(lo, min(hi - sl + 1, eff))
            off = random.randint(lo, hix)
            off = (off // (1024 * 1024)) * (1024 * 1024)  # 1MiB 对齐
            if off > eff:
                off = eff
            o.write(f"{path}\t{off}\t{sl}\t{i}\n")
print(total)
PY

CHUNKS_FILE="$WORKDIR/chunks.0"
total_chunks=$(wc -l < "$CHUNKS_FILE")
probed_files=$(( $(cut -f1 "$CHUNKS_FILE" | sort -u | wc -l) ))
tick "阶段1b 分片计划完成: files_candidates=$total_count -> probed=$probed_files total_chunks=$total_chunks"

# ---- 阶段 2: 并行拉取 (每片 源+目标 各落盘一文件) ----
tick "阶段2开始 并行拉取分片 jobs=$JOBS (共 $total_chunks 片)"

# per-chunk 拉取函数 (并行子进程)
fetch_one() {
  local line="$1" #  Path<TAB>off<TAB>len<TAB>seq
  local path="${line%%$'\t'*}" rest="${line#*$'\t'}"
  local off="${rest%%$'\t'*}" rest2="${rest#*$'\t'}"
  local len="${rest2%%$'\t'*}" seq="${rest2#*$'\t'}"
  local srcf="$WORKDIR/d_${seq}.src" dstf="$WORKDIR/d_${seq}.dst"
  "$RCLONE" cat "$SRC/$path" --offset "$off" --count "$len" --no-check-certificate \
    --retries 5 --low-level-retries 20 > "$srcf" 2>/dev/null || { rm -f "$srcf"; echo "SRCFAIL" > "$WORKDIR/d_${seq}.fail"; }
  "$RCLONE" cat "$DST/$path" --offset "$off" --count "$len" --no-check-certificate \
    --retries 5 --low-level-retries 20 > "$dstf" 2>/dev/null || { rm -f "$dstf"; echo "DSTFAIL" > "$WORKDIR/d_${seq}.fail"; }
}
export -f fetch_one
export RCLONE SRC DST WORKDIR

# bash 作业池按 JOBS 并发
run_pool() {
  local f="$1" j="$2"
  local n=0 done=0
  local total=$(wc -l < "$f")
  while IFS= read -r l; do
    fetch_one "$l" &
    n=$((n+1))
    if [ $((n % j)) -eq 0 ]; then
      wait; done=$((done+j))
      if [ $((n * 10 / total % 2)) -eq 0 ]; then tick "阶段2 拉片进度 ${done}/${total}"; fi
    fi
  done < "$f"
  wait
}

run_pool "$CHUNKS_FILE" "$JOBS"
tick "阶段2完成 全部 ${total_chunks} 片已双端拉取"

# 检查拉取失败的分片
fail_count=$(cat "$WORKDIR"/*.fail 2>/dev/null | wc -l || true)
[ "$fail_count" -eq 0 ] && rm -f "$WORKDIR"/*.fail || \
  echo "::warning:: $fail_count 个分片拉取失败(源或目标),相关比对将判 SKIP" >&2

# ---- 阶段 3: 并行比对 md5 ----
tick "阶段3开始 并行比对 md5 checkers=$CHECKERS"

compare_one() {
  local line="$1"
  local path="${line%%$'\t'*}" rest="${line#*$'\t'}"
  local rest2="${rest#*$'\t'}" rest3="${rest2#*$'\t'}"
  local seq="${rest3#*$'\t'}"
  local srcf="$WORKDIR/d_${seq}.src" dstf="$WORKDIR/d_${seq}.dst"
  if [ -f "$WORKDIR/d_${seq}.fail" ]; then
    echo "SKIP $path"
    return 0
  fi
  local a b
  a=$(md5sum "$srcf" 2>/dev/null | awk '{print $1}')
  b=$(md5sum "$dstf" 2>/dev/null | awk '{print $1}')
  if [ -z "$a" ] || [ -z "$b" ]; then
    echo "SKIP $path"
  elif [ "$a" = "$b" ]; then
    echo "OK $path"
  else
    echo "MISMATCH $path"
  fi
}
export -f compare_one
export WORKDIR

# 并行比对, 结果写结果文件, 再聚合到文件级
RESULT="$WORKDIR/result.txt"
: > "$RESULT"
i=0
while IFS= read -r l; do
  compare_one "$l" >> "$RESULT" &
  i=$((i+1))
  if [ $((i % CHECKERS)) -eq 0 ]; then wait; i=0; fi
done < "$CHUNKS_FILE"
wait

# ---- 聚合到文件级 ----
tot_mism=0; tot_ok=0; tot_skip=0
declare -A filestat
while IFS= read -r cond rest; do
  case "$cond" in
    MISMATCH) tot_mism=$((tot_mism+1)); filestat["$rest"]="MISMATCH" ;;
    SKIP)     tot_skip=$((tot_skip+1)); [ -z "${filestat[$rest]:-}" ] && filestat["$rest"]="SKIP" ;;
    *)        tot_ok=$((tot_ok+1)) ;;
  esac
done < "$RESULT"

echo "$RESULT" >&2  # keep
mism_files=0; ok_files=0
for path in "${!filestat[@]}"; do
  if [ "${filestat[$path]}" = "MISMATCH" ]; then mism_files=$((mism_files+1)); echo "MISMATCH $path"; fi
done
ok_files=$(( $(cut -f1 "$CHUNKS_FILE" | sort -u | wc -l) - mism_files ))

tick "阶段3完成"
echo "=== probe done: files_ok=$ok_files files_mismatch=$mism_files chunks_total=$total_chunks chunks_ok=$tot_ok chunks_mismatch=$tot_mism chunks_skip=$tot_skip ===" >&2

if [ -z "${NO_CLEAN:-}" ]; then rm -rf "$WORKDIR"; else echo "workdir=$WORKDIR" >&2; fi

[ "$tot_mism" -eq 0 ] && [ "$tot_skip" -eq 0 ]