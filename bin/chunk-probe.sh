#!/usr/bin/env bash
#
# chunk-probe.sh — 基于随机分片 Range 下载的双端内容比对探针
#
# 目的:对 source 桶与 wopan 目标端做"分片级"内容抽样比对,快速定位大体量文件的内容损坏,
#       而不必把整个文件下载下来 (整文件抽样对大 ISO 慢)。
#
# 策略 (单文件粒度):
#   - 对每个待检文件, 分片数 N = min(ceil(Size / 100MiB), 100), 至少 1 片
#   - 文件被均匀切为 N 个等宽区间, 每区间内选 1 个随机偏移 (offset), 两端各用
#     rclone cat --offset <off> --count <SLICE> 拉取该片段 (走 HTTP Range -> 206),
#     对比两端 md5. 任何一片不一致判定该文件损坏 (无需整文件下载)。
#   - 偏移与切片长度按 1MiB 对齐, 避免字节级 Range 边界分叉。
#
# 用法:
#   chunk-probe.sh <src:path> <dst:path> [--limit N] [--min-size M] [--slice S]
#   src/dst 是 rclone remote 路径 (如 src:bucket / wopan:s3-bak/<bucket>).
#
# 环境变量:
#   RCLONE  : rclone 可执行文件路径 (默认 rclone)
#   SLICE   : 单片下载长度字节, 1MiB 对齐 (默认 4MiB)
#   LIMIT   : 最多探测多少个文件 (默认全部)
#   MIN_SIZE: 只探测 >= 该字节的对象 (默认 1MiB, 跳过小文件避免请求过载)
#
# 输出:
#   每文件一行结果到 stdout, 汇总到 stderr; 结束码 0=全部一致, 1=发现不一致。

set -euo pipefail

RCLONE="${RCLONE:-rclone}"
SLICE="${SLICE:-4194304}"          # 4MiB
LIMIT="${LIMIT:--1}"
MIN_SIZE="${MIN_SIZE:-1048576}"    # 1MiB
CHUNK_PER_100M=104857600

SRC="${1:?src:path required}"
DST="${2:?dst:path required}"

probe_err=/tmp/chunk-probe.err

# 计算流式 stdin 的 md5 (openssl 与 md5sum 二选一)
mmd5() {
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -md5 2>/dev/null | awk '{print $NF}'
  else
    cat | md5sum | awk '{print $1}'
  fi
}

# 对齐到 1MiB
align() {
  local off="$1" step=$((1024*1024))
  echo $(( off / step * step ))
}

declare -a FILES=()
mapfile -t FILES < <(
  "$RCLONE" lsjson "$SRC" -R --files-only --no-mimetype --no-modtime \
    | jq -r '.[] | select(.Size >= '"$MIN_SIZE"') | [.Path, .Size] | @tsv'
)

total_count=${#FILES[@]}
echo "probe src=$SRC dst=$DST slice=$SLICE limit=$LIMIT files_candidates=$total_count"

probed=0; mism=0; skip=0
for row in "${FILES[@]}"; do
  [ "$LIMIT" -ne -1 ] && [ "$probed" -ge "$LIMIT" ] && break
  p="${row%%$'\t'*}"; size="${row##*$'\t'}"
  [ "$size" -gt 0 ] || { skip=$((skip+1)); continue; }

  n=$(( (size + CHUNK_PER_100M - 1) / CHUNK_PER_100M ))
  [ "$n" -lt 1 ] && n=1
  [ "$n" -gt 100 ] && n=100
  eff=$(( size - SLICE ))
  [ "$eff" -lt 0 ] && eff=0

  echo "== $p (size=$size slices=$n slice=$SLICE)" >&2

  ok=1
  for ((i=0;i<n;i++)); do
    lo=$(( size * i / n ))              # 区间起点
    hi=$(( size * (i+1) / n - 1 ))      # 区间终点
    hix=$(( hi - SLICE + 1 ))
    [ "$hix" -lt "$lo" ] && hix="$lo"
    [ "$hix" -gt "$eff" ] && hix="$eff"
    [ "$hix" -lt 0 ] && hix=0
    off=$(awk -v lo="$lo" -v hix="$hix" 'BEGIN{srand(); print int(lo + rand()*(hix-lo+1))}')
    off=$(align "$off")
    # 对齐后可能越过区间边界/文件尾,收回到合法范围
    maxoff=$(( size - SLICE )); [ "$maxoff" -lt 0 ] && maxoff=0
    [ "$off" -gt "$maxoff" ] && off="$maxoff"

    a=$("$RCLONE" cat "$SRC/$p" --offset "$off" --count "$SLICE" --no-check-certificate --retries 5 2>/dev/null | mmd5)
    b=$("$RCLONE" cat "$DST/$p" --offset "$off" --count "$SLICE" --no-check-certificate --retries 5 2>/dev/null | mmd5)
    if [ -z "$a" ] || [ -z "$b" ]; then
      echo "   SKIP chunk@$off (读取失败)" >&2; ok=0; continue
    fi
    if [ "$a" != "$b" ]; then
      echo "   MISMATCH chunk@$off src=$a dst=$b" >&2
      ok=0; mism=$((mism+1))
    else
      echo "   match chunk@$off" >&2
    fi
  done
  probed=$((probed+1))
  [ "$ok" -eq 1 ] && echo "MATCH $p"
done

echo "=== probe done: probed=$probed skipped=$skip mismatched_slices=$mism ===" >&2
[ "$mism" -eq 0 ]