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
#   RCLONE    : rclone 可执行文件路径 (默认 rclone)
#   SLICE     : 单片下载长度字节 (默认 2097152 = 2MiB)
#   LIMIT     : top-N 大文件档位 (默认 -1 = 全部;与 RANDOM_PICK 互斥,优先 RANDOM_PICK)
#   RANDOM_PICK: 随机抽样 N 个文件(0/空 = 不用随机,按 LIMIT 取大文件)。迁移 verify 用 50。
#   MIN_SIZE  : 只探测 >= 该字节对象 (默认 1048576 = 1MiB)
#   JOBS      : 并行拉取作业数 (默认 32, 每片源+目标各一连接)
#   CHECKERS  : 并行 md5 校验作业数 (默认 4)
#   DEL_MISMATCH: 非空则分片不一致时删除目标端对应文件(rclone deletefile),用于迁移 verify 自治
#   CHUNKS_PER_FILE: 每个文件固定抽多少片 (默认 10)
#
# 输出:每文件一行结果到 stdout / 汇总与错误到 stderr;
#       退出码 0=全部一致(允许 skip), 1=发现不一致(已删除目标坏文件,重跑 sync 修复)。

set -euo pipefail

RCLONE="${RCLONE:-rclone}"
SLICE="${SLICE:-2097152}"          # 2MiB(减半,提升分片数量与命中率)
LIMIT="${LIMIT:--1}"
RANDOM_PICK="${RANDOM_PICK:-0}"    # 随机抽样 N 个文件(>0 生效,优先于 LIMIT top-N)
MIN_SIZE="${MIN_SIZE:-1048576}"    # 1MiB
JOBS="${JOBS:-100}"                # 网络无成本,高并发摊薄 rclone 进程启动开销(32 实测偏慢)
CHECKERS="${CHECKERS:-4}"
CHUNKS_PER_FILE="${CHUNKS_PER_FILE:-10}"   # 每个文件固定抽 10 片(默认)
DEL_MISMATCH="${DEL_MISMATCH:-}"   # 非空 = 分片不一致时删目标端文件(迁移 verify 自治)
VERBOSE="${VERBOSE:-0}"            # 非空/非0 = 每片完成都打 tick(默认每 1/10 打一次,VERBOSE 逐片)
PYTHON="${PYTHON:-python3}"
# 固定诊断目录名,便于 workflow 用 upload-artifact 稳定打包;探测只读且按桶分组串行,
# 不同 bucket 各自 runner 独立 /tmp 无冲突。
WORKDIR="/tmp/probe-artifact"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"

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
# 注意:set -e 下,简单命令非零返回立即自杀,LIST_RC=$? 永远到达不了;
# 必须用 if 或 cmd || true 才能捕获退出码(此前 LIST_RC 检查是死代码,lsjson 失败直接 exit 1)。
if "$RCLONE" lsjson "$SRC" -R --files-only --no-mimetype --no-modtime -vv \
   2>"$WORKDIR/lsjson.vv.log" >"$FILES_JSON"; then
  LIST_RC=0
else
  LIST_RC=$?
  # 部分失败(如 OSS 瞬断读某个对象)可能 lsjson 返回非零但 files.json 已有内容;
  # 只要 JSON 非空且可解析,继续走下去(跳过那一个坏对象);真正全空/不可解析才报错退出。
  if [ -s "$FILES_JSON" ]; then
    echo "::warning::lsjson rc=$LIST_RC(部分失败,files.json 有内容,继续处理已有数据)" >&2
  else
    echo "::error::lsjson 失败 rc=$LIST_RC,files.json 为空 (见 lsjson.vv.log)" >&2
    tail -20 "$WORKDIR/lsjson.vv.log" >&2
    exit 1
  fi
fi
tick "阶段1a 完成 lsjson -> files.json ($(du -h "$FILES_JSON" | cut -f1))"

# python:从 files.json 取文件并生成平铺分片清单
# 不在 bash 里建大数组; python json.load 一次性读 + 内存排序/随机, 比 bash mapfile 可靠。
# 抽样: RANDOM_PICK>0 → 全桶随机抽 N 个文件(LIMIT 忽略);否则 top-LIMIT 大文件。
# 分片策略: 每文件固定 CHUNKS_PER_FILE 段(默认 10),把文件均分 N 段、每段内 1MiB
# 对齐随机取一个偏移——相比按体积(每 100MiB 一片)对超大片会切出几百片、进程启动
# 开销爆炸(每片起 2 个 rclone),固定 10 片总量可控且首中尾都被覆盖,命中率更高。
if [ "$RANDOM_PICK" -gt 0 ] 2>/dev/null; then
  PICK_LABEL="全桶随机 ${RANDOM_PICK} 个文件"
else
  PICK_LABEL="top ${LIMIT} 大文件"
fi
tick "阶段1b 分片计划 ($PICK_LABEL, 每文件 ${CHUNKS_PER_FILE} 片)..."
total_count=$("$PYTHON" - "$FILES_JSON" "$WORKDIR/chunks.0" "$CHUNKS_PER_FILE" "$SLICE" "$LIMIT" "$MIN_SIZE" "$RANDOM_PICK" <<'PY')
import sys, math, random, json
fj, out, cpf, sl, lim, minsz, rpick = sys.argv[1:]
cpf, sl, minsz, lim, rpick = int(cpf), int(sl), int(minsz), int(lim), int(rpick)
with open(fj) as f:
    data = json.load(f)
files = [(o["Path"], int(o["Size"])) for o in data if int(o["Size"]) >= minsz]
total = len(files)
random.seed(0x5EED)  # 固定种子,结果可复现(排查友好)
if rpick > 0:
    # 全桶随机抽 N 个(不按体积偏置;文件不足 N 则全取)
    random.shuffle(files)
    files = files[:rpick]
elif lim >= 0:
    # 降序取 limit (聚焦大文件; -1=全部)
    files.sort(key=lambda x: -x[1])
    files = files[:lim]
gseq = 0  # 全局唯一分片序号! 过去误用每文件片内索引 i(0..9),5 文件×10 片全冲突,
          # d_<seq>.src/.dst/.fail 互相覆盖 → compare 读错文件、SKIP 全挂。
with open(out, "w") as o:
    for path, size in files:
        # 文件均分 cpf 段,每段取一个 1MiB 对齐偏移;文件过小(<cpf 倍片长)则退化整文件取首片
        n = max(1, min(cpf, size // sl if size >= sl else 1))
        eff = max(0, size - sl)
        step = size / n
        for i in range(n):
            lo = int(i * step)
            hi = int((i + 1) * step) - 1
            hix = max(lo, min(hi - sl + 1, eff))
            off = random.randint(lo, hix) if hix >= lo else lo
            off = (off // (1024 * 1024)) * (1024 * 1024)  # 1MiB 对齐
            if off > eff:
                off = eff
            o.write(f"{path}\t{off}\t{sl}\t{gseq}\n")
            gseq += 1
print(total)
PY

CHUNKS_FILE="$WORKDIR/chunks.0"
total_chunks=$(wc -l < "$CHUNKS_FILE")
probed_files=$(( $(cut -f1 "$CHUNKS_FILE" | sort -u | wc -l) ))
tick "阶段1b 分片计划完成: files_candidates=$total_count -> probed=$probed_files total_chunks=$total_chunks"

# ---- 阶段 2: 并行拉取 (每片 源+目标 各落盘一文件) ----
: > "$WORKDIR/sizes.tsv"
# 汇总文件(供 artifact)之前若存在则清零
: > "$WORKDIR/result.txt"
tick "阶段2开始 并行拉取分片 jobs=$JOBS (共 $total_chunks 片)"

# per-chunk 拉取函数 (并行子进程)
# 双端并行: 源端与目标端同时拉取(此前串行,慢的一端独占时间)。
# 取证设计: 不丢弃 rclone stderr(存 d_<seq>.src/.dst.log),落盘后 du -b 核对实际字节,
#           与请求 len 对比:远大于 len → 疑似未走 Range、整文件下载(计入 sizes 供诊断)。
fetch_one() {
  local line="$1" #  Path<TAB>off<TAB>len<TAB>seq
  local path="${line%%$'\t'*}" rest="${line#*$'\t'}"
  local off="${rest%%$'\t'*}" rest2="${rest#*$'\t'}"
  local len="${rest2%%$'\t'*}"
  local seq="${rest2#*$'\t'}"
  local srcf="$WORKDIR/d_${seq}.src" dstf="$WORKDIR/d_${seq}.dst"
  # 双端并行拉取(后台 & 同时跑,完了 wait)
  ( "$RCLONE" cat "$SRC/$path" --offset "$off" --count "$len" --no-check-certificate \
      --retries 5 --low-level-retries 20 > "$srcf" 2>"$WORKDIR/d_${seq}.src.log" \
      || { rm -f "$srcf"; echo "SRCFAIL $path" > "$WORKDIR/d_${seq}.fail"; } ) &
  local pidsrc=$!
  ( "$RCLONE" cat "$DST/$path" --offset "$off" --count "$len" --no-check-certificate \
      --retries 5 --low-level-retries 20 > "$dstf" 2>"$WORKDIR/d_${seq}.dst.log" \
      || { rm -f "$dstf"; echo "DSTFAIL $path" > "$WORKDIR/d_${seq}.fail"; } ) &
  local piddst=$!
  wait "$pidsrc" || true
  wait "$piddst" || true
  # 落盘字节核对(仅在文件存在时统计;失败文件会被 rm 掉,du 返回 0)
  local ss=$(( $(du -b "$srcf" 2>/dev/null | cut -f1) + 0 ))
  printf '%s\tSRC\t%s\t%s\t%s\n' "$seq" "$ss" "$len" "$path" >> "$WORKDIR/sizes.tsv"
  if [ "$ss" -gt $(( len + 1048576 )) ]; then  # 超过 len 1MiB 容差 = 疑似全量下载
    echo "::warning::WARN 源端疑似整文件下载 seq=$seq off=$off want=$len got=$ss $path" >&2
  fi
  local ds=$(( $(du -b "$dstf" 2>/dev/null | cut -f1) + 0 ))
  printf '%s\tDST\t%s\t%s\t%s\n' "$seq" "$ds" "$len" "$path" >> "$WORKDIR/sizes.tsv"
  if [ "$ds" -gt $(( len + 1048576 )) ]; then
    echo "::warning::WARN 目标端疑似整文件下载 seq=$seq off=$off want=$len got=$ds $path" >&2
  fi
}
export -f fetch_one
export RCLONE SRC DST WORKDIR VERBOSE

# 滑动窗口作业池: 不整批 wait,窗口满即等一个结束并补位,消灭"整批等最慢"的黑洞
run_pool() {
  local f="$1" j="$2"
  local total=$(wc -l < "$f")
  local -a pids=()
  local n=0 done=0
  while IFS= read -r l; do
    fetch_one "$l" &
    pids+=("$!")
    n=$((n+1))
    # 达到窗口上限 → 等任意一个结束(累计 done),过滤已死 pid,立即补位
    if [ "${#pids[@]}" -ge "$j" ]; then
      wait -n 2>/dev/null || true
      done=$((done+1))
      local -a alive=()
      local p
      for p in "${pids[@]}"; do
        if kill -0 "$p" 2>/dev/null; then alive+=("$p"); fi
      done
      pids=("${alive[@]}")
    fi
    # 打完成进度:VERBOSE=1 每 5 片打一次(100 并发下逐片太刷屏,5 片粒度足够看推进);
    # 默认每完成 total/10 打一次
    if [ "${#pids[@]}" -ge "$j" ]; then
      if [ "$VERBOSE" = "1" ]; then
        if [ $((done % 5)) -eq 0 ] || [ "$done" -eq "$total" ]; then
          tick "阶段2 完成 ${done}/${total}"
        fi
      elif [ $(( done * 10 / total )) -gt $(( (done - 1) * 10 / total )) ]; then
        tick "阶段2 完成 ${done}/${total}"
      fi
    fi
  done < "$f"
  wait
  done=$total
  tick "阶段2 拉片全部结束(共 ${done})"
}
run_pool "$CHUNKS_FILE" "$JOBS"
tick "阶段2完成 全部 ${total_chunks} 片已双端拉取"

# 检查拉取失败的分片
# 用文件数统计而非 wc -l 行数——两端都失败时 SRCFAIL/DSTFAIL 覆盖写入,文件仍只算 1 片
fail_files=$(find "$WORKDIR" -name 'd_*.fail' 2>/dev/null | wc -l || true)
if [ "$fail_files" -gt 0 ]; then
  echo "::warning:: $fail_files 个分片拉取失败(源或目标),相关比对将判 SKIP" >&2
else
  rm -f "$WORKDIR"/*.fail
fi

# ---- 阶段 3: 并行比对 md5 ----
tick "阶段3开始 并行比对 md5 checkers=$CHECKERS"

compare_one() {
  local line="$1"
  local path="${line%%$'\t'*}" rest="${line#*$'\t'}"
  # 注意:set -u 下同一行 local 声明后,右值引用同名/相邻变量仍被视为未绑定,
  #       必须拆行逐个 local 再引用,否则 unbound variable。
  local rest2="${rest#*$'\t'}"
  local rest3="${rest2#*$'\t'}"
  local seq="${rest3#*$'\t'}"
  local srcf="$WORKDIR/d_${seq}.src" dstf="$WORKDIR/d_${seq}.dst"
  if [ -f "$WORKDIR/d_${seq}.fail" ]; then
    echo "SKIP(file_fail) $path"
    return 0
  fi
  local a b
  a=$(md5sum "$srcf" 2>/dev/null | awk '{print $1}')
  b=$(md5sum "$dstf" 2>/dev/null | awk '{print $1}')
  if [ -z "$a" ] || [ -z "$b" ]; then
    echo "SKIP(md5_empty) $path"
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
tot_mism=0; tot_ok=0; tot_skip=0; skip_ff=0; skip_me=0
declare -A filestat
: > "$WORKDIR/mismatch_files.txt"
while IFS= read -r cond rest; do
  case "$cond" in
    MISMATCH)          tot_mism=$((tot_mism+1)); filestat["$rest"]="MISMATCH"; echo "$rest" >> "$WORKDIR/mismatch_files.txt" ;;
    SKIP*)             tot_skip=$((tot_skip+1))
                       case "$cond" in
                         SKIP\(file_fail\))  skip_ff=$((skip_ff+1)) ;;
                         SKIP\(md5_empty\))   skip_me=$((skip_me+1)) ;;
                       esac
                       [ -z "${filestat[$rest]:-}" ] && filestat["$rest"]="SKIP" ;;
    *)                 tot_ok=$((tot_ok+1)) ;;
  esac
done < "$RESULT"

# 交叉验证:阶段2统计的 .fail 文件数 vs 阶段3 result.txt 里的 SKIP(file_fail) 行数
cross_ok=1
if [ "$skip_ff" -ne "$fail_files" ]; then
  echo "::warning::计数不一致:阶段2有 $fail_files 个 .fail 文件,但阶段3只看到 $skip_ff 个 SKIP(file_fail)" >&2
  cross_ok=0
fi

echo "$RESULT" >&2  # keep
mism_files=0; ok_files=0
for path in "${!filestat[@]}"; do
  if [ "${filestat[$path]}" = "MISMATCH" ]; then mism_files=$((mism_files+1)); echo "MISMATCH $path"; fi
done
ok_files=$(( $(cut -f1 "$CHUNKS_FILE" | sort -u | wc -l) - mism_files ))

# DEL_MISMATCH:迁移 verify 自治——把不一致的目标文件删掉,重跑 sync 即重传修复。
# 串行逐个删(失败不影响其他),删除走 rclone deletefile(幂等,文件不存在也成功)。
# 注:SRC/DST/RCLONE 已在 fetch 段 export,此处(主进程)直接可见。
if [ -n "$DEL_MISMATCH" ] && [ "$mism_files" -gt 0 ]; then
  echo "== DEL_MISMATCH 已开启,删除 $mism_files 个不一致目标文件 ==" >&2
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if "$RCLONE" deletefile --no-check-certificate "$DST/$p" --retries 5 \
       2>"$WORKDIR/del.err"; then
      echo "  deleted: $p" >&2
    else
      echo "::warning::删除失败(目标端): $p" >&2
    fi
  done < "$WORKDIR/mismatch_files.txt"
fi

tick "阶段3完成"
echo "=== probe done: files_ok=$ok_files files_mismatch=$mism_files chunks_total=$total_chunks chunks_ok=$tot_ok chunks_mismatch=$tot_mism chunks_skip=$tot_skip (skip_ff=$skip_ff skip_me=$skip_me fail_files=$fail_files cross_ok=$cross_ok) ===" >&2

# 保留诊断文件供 artifact(字节核对 sizes.tsv / lsjson.vv.log / 各片 rclone 日志 / result)
# WORKDIR 默认保留;设 CLEANUP=1 时才删除。分片本体(大)在比对后可删,留 *.log/tsv/result。
if [ "${CLEANUP:-}" = "1" ]; then
  find "$WORKDIR" -name 'd_*.src' -o -name 'd_*.dst' | xargs -r rm -f
  rm -f "$WORKDIR/chunks.0"
fi
echo "WORKDIR_ARTIFACT=$WORKDIR" >&2

# 退出语义: 仅发现不一致(MISMATCH,且已 DEL_MISMATCH 删除目标)才非 0;
# 拉取失败(SKIP)不致命——目标端目录缺失等 read 失败由 sync 阶段 size-only 兜底。
[ "$tot_mism" -eq 0 ]