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
#   chunk-probe.sh [选项] <src:path> <dst:path>
#   (选项必须在两个路径之前:解析器遇到第一个非选项参数即停止,后面的选项会被当成路径忽略)
#
# 选项 (优先级:命令行 > 环境变量 > 默认值):
#   --limit N               top-N 大文件档位 (-1=全部,默认 -1;与 --random-pick 互斥)
#   --random-pick N         全桶随机抽 N 个文件 (0=不用,默认 0)
#   --chunks-per-file N     每个文件固定抽多少片 (默认 10)
#   --slice BYTES           单片下载长度字节 (默认 2097152 = 2MiB)
#   --min-size BYTES        只探测 >= 该字节对象 (默认 1048576 = 1MiB)
#   --jobs N                并行拉取作业数 (默认 100, 源+目标各一连接)
#   --checkers N            并行 md5 校验作业数 (默认 4)
#   --del-mismatch          分片不一致时删除目标端对应文件(迁移 verify 自治)
#   --verbose               逐片打进度 tick
#   --help, -h              显示帮助并退出
#
# 环境变量 (命令行未指定时生效):
#   RCLONE    : rclone 可执行文件路径 (默认 rclone)
#   PYTHON    : python 可执行文件路径 (默认 python3)
#
# 输出:每文件一行结果到 stdout / 汇总与错误到 stderr;
#       退出码 0=全部一致(允许 skip), 1=发现不一致(已删除目标坏文件,重跑 sync 修复)。

set -euo pipefail

# ---- 命令行参数解析 (命令行 > 环境变量 > 默认值) ----
_LIMIT=""; _RANDOM_PICK=""; _CHUNKS_PER_FILE=""; _SLICE=""; _MIN_SIZE=""; _JOBS=""; _CHECKERS=""; _DEL_MISMATCH=""; _VERBOSE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --limit)            _LIMIT="$2";            shift 2 ;;
    --random-pick)      _RANDOM_PICK="$2";      shift 2 ;;
    --chunks-per-file)  _CHUNKS_PER_FILE="$2";  shift 2 ;;
    --slice)            _SLICE="$2";            shift 2 ;;
    --min-size)         _MIN_SIZE="$2";         shift 2 ;;
    --jobs)             _JOBS="$2";             shift 2 ;;
    --checkers)         _CHECKERS="$2";         shift 2 ;;
    --del-mismatch)     _DEL_MISMATCH=1;        shift ;;
    --verbose)          _VERBOSE=1;             shift ;;
    --help|-h)
      sed -n '2,34p' "$0"
      exit 0 ;;
    --) shift; break ;;
    -*) echo "未知参数: $1 (用法见 --help)" >&2; exit 2 ;;
    *) break ;;   # 位置参数 (src dst) 开始,跳出
  esac
done

RCLONE="${RCLONE:-rclone}"
PYTHON="${PYTHON:-python3}"
SLICE="${_SLICE:-${SLICE:-2097152}}"       # 2MiB
LIMIT="${_LIMIT:-${LIMIT:--1}}"
RANDOM_PICK="${_RANDOM_PICK:-${RANDOM_PICK:-0}}"
MIN_SIZE="${_MIN_SIZE:-${MIN_SIZE:-1048576}}"
JOBS="${_JOBS:-${JOBS:-100}}"
CHECKERS="${_CHECKERS:-${CHECKERS:-4}}"
CHUNKS_PER_FILE="${_CHUNKS_PER_FILE:-${CHUNKS_PER_FILE:-10}}"
DEL_MISMATCH="${_DEL_MISMATCH:-${DEL_MISMATCH:-}}"
VERBOSE="${_VERBOSE:-${VERBOSE:-0}}"
# 取数方式: rclone=每片一个 rclone cat(默认, 现有生产路径); aria2=每文件签一次直链再并行拉
FETCH_MODE="${FETCH_MODE:-rclone}"
ARIA2="${ARIA2:-aria2c}"
RCD_ADDR="${RCD_ADDR:-127.0.0.1:5579}"
SIGN_JOBS="${SIGN_JOBS:-8}"
ARIA2_TRIES="${ARIA2_TRIES:-2}"
CHUNK_TIMEOUT="${CHUNK_TIMEOUT:-20}"          # aria2 单连接静默超时(秒)
CHUNK_CONNECT_TIMEOUT="${CHUNK_CONNECT_TIMEOUT:-10}"
STAGE2_DEADLINE="${STAGE2_DEADLINE:-900}"     # 整个取数阶段的墙钟上限(秒)
ARIA2_LOG="${ARIA2_LOG:-/tmp/aria2-probe.log}"  # 原始 aria2 日志(含签名 URL, 不入 artifact)
PROBE_SEED="${PROBE_SEED:-0x5EED}"   # 抽样种子(接受 0x.. 或十进制);执行器按 run id 传值,轮间换一批文件

# 固定诊断目录名,便于 workflow 用 upload-artifact 稳定打包;探测只读且按桶分组串行,
# 不同 bucket 各自 runner 独立 /tmp 无冲突。
WORKDIR="/tmp/probe-artifact"
# 两个子目录分开存放,便于 workflow 分两个 artifact 上传:
#   diag = 小尺寸诊断文件(清单/结果/各片日志/失败标记),常备、秒下载
#   chunks = 大体积分片本体(d_*.src/.dst), 取证才拉
WORKDIR_DIAG="$WORKDIR/diag"
WORKDIR_CHUNKS="$WORKDIR/chunks"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR_DIAG" "$WORKDIR_CHUNKS"

SRC="${1:?src:path required}"
DST="${2:?dst:path required}"

# 源端 CDN 下载域: 从 conf 的 [<remote>] 段读 download_host, 供 aria2 模式改写 host;
# 读不到就留空(不改写, 直连源站), 不影响 rclone 模式。
SRC_DOWNLOAD_HOST=""
if [ -n "${RCLONE_CONFIG:-}" ] && [ -r "${RCLONE_CONFIG}" ]; then
  SRC_DOWNLOAD_HOST=$(awk -v s="[${SRC%%:*}]" '
    /^\[/ { insec = ($0 == s); next }
    insec && /^[ \t]*download_host[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit }
  ' "$RCLONE_CONFIG" 2>/dev/null || true)
fi

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
FILES_JSON="$WORKDIR_DIAG/files.json"
# 注意:set -e 下,简单命令非零返回立即自杀,LIST_RC=$? 永远到达不了;
# 必须用 if 或 cmd || true 才能捕获退出码(此前 LIST_RC 检查是死代码,lsjson 失败直接 exit 1)。
if "$RCLONE" lsjson "$SRC" -R --files-only --no-mimetype --no-modtime -vv \
   ${PROBE_MAX_SIZE:+--max-size "$PROBE_MAX_SIZE"} \
   2>"$WORKDIR_DIAG/lsjson.vv.log" >"$FILES_JSON"; then
  LIST_RC=0
else
  LIST_RC=$?
  # 部分失败(如 OSS 瞬断读某个对象)可能 lsjson 返回非零但 files.json 已有内容;
  # 只要 JSON 非空且可解析,继续走下去(跳过那一个坏对象);真正全空/不可解析才报错退出。
  if [ -s "$FILES_JSON" ]; then
    echo "::warning::lsjson rc=$LIST_RC(部分失败,files.json 有内容,继续处理已有数据)" >&2
  else
    echo "::error::lsjson 失败 rc=$LIST_RC,files.json 为空 (见 lsjson.vv.log)" >&2
    tail -20 "$WORKDIR_DIAG/lsjson.vv.log" >&2
    exit 1
  fi
fi
tick "阶段1a 完成 lsjson -> files.json ($(du -h "$FILES_JSON" | cut -f1))"

# 列出 0 个对象也算失败,而且 -s 判不出来:2026-10-04 实测源端 403 UserDisable 时
# lsjson 非零返回却写了一个 `[]`(2 字节),流程继续走到 python 的 json.load 才崩,
# 日志里只剩一句 traceback,看着像脚本坏了而不是"源桶读不到"。这里直接把根因说清楚。
if ! grep -q '"Path"' "$FILES_JSON"; then
  echo "::error::lsjson 列出 0 个对象(rc=$LIST_RC),源桶不可读,原因见下 (lsjson.vv.log)" >&2
  grep -aE 'NOTICE|ERROR' "$WORKDIR_DIAG/lsjson.vv.log" 2>/dev/null | tail -3 >&2
  exit 1
fi

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
total_count=$("$PYTHON" - "$FILES_JSON" "$WORKDIR_DIAG/chunks.0" "$CHUNKS_PER_FILE" "$SLICE" "$LIMIT" "$MIN_SIZE" "$RANDOM_PICK" "$PROBE_SEED" <<'PY')
import sys, math, random, json
fj, out, cpf, sl, lim, minsz, rpick, seed = sys.argv[1:]
cpf, sl, minsz, lim, rpick = int(cpf), int(sl), int(minsz), int(lim), int(rpick)
with open(fj, encoding="utf-8") as f:
    data = json.load(f)
files = [(o["Path"], int(o["Size"])) for o in data if int(o["Size"]) >= minsz]
total = len(files)
# 抽样种子。默认仍是 0x5EED(单轮排查可复现);但固定种子会让每一轮抽到**同一批文件**,
# 多轮迁移永远只验同样的 50 个。执行器把 PROBE_SEED 设成 run id,轮间就自动换一批,
# 需要复刻某轮时按那轮的 run id 传回同一个值即可。
random.seed(int(seed, 0))
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
with open(out, "w", encoding="utf-8", newline="\n") as o:
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

CHUNKS_FILE="$WORKDIR_DIAG/chunks.0"
total_chunks=$(wc -l < "$CHUNKS_FILE")
probed_files=$(( $(cut -f1 "$CHUNKS_FILE" | sort -u | wc -l) ))
tick "阶段1b 分片计划完成: files_candidates=$total_count -> probed=$probed_files total_chunks=$total_chunks"

# ---- 阶段 2: 并行拉取 (每片 源+目标 各落盘一文件) ----
: > "$WORKDIR_DIAG/sizes.tsv"
# 汇总文件(供 artifact)之前若存在则清零
: > "$WORKDIR_DIAG/result.txt"
tick "阶段2开始 并行拉取分片 jobs=$JOBS (共 $total_chunks 片)"

# per-chunk 拉取函数 (并行子进程)
# 双端并行: 源端与目标端同时拉取(此前串行,慢的一端独占时间)。
# 取证设计: 不丢弃 rclone stderr(存 d_<seq>.src/.dst.log),落盘后 du -b 核对实际字节,
#           与请求 len 对比:远大于 len → 疑似未走 Range、整文件下载(计入 sizes 供诊断)。
# 源端读失败的形态分类。敏感词目录在服务端表现为 "directory not found"(读不到路径本身),
# 与一般网络失败不是同一类缺口,混计会让桶级缺口统计不可用。
src_fail_kind() {
  if grep -qF 'directory not found' "$1" 2>/dev/null; then echo SRCNONAME; else echo SRCFAIL; fi
}

fetch_one() {
  local line="$1" #  Path<TAB>off<TAB>len<TAB>seq
  local path="${line%%$'\t'*}" rest="${line#*$'\t'}"
  local off="${rest%%$'\t'*}" rest2="${rest#*$'\t'}"
  local len="${rest2%%$'\t'*}"
  local seq="${rest2#*$'\t'}"
  local srcf="$WORKDIR_CHUNKS/d_${seq}.src" dstf="$WORKDIR_CHUNKS/d_${seq}.dst"
  # 双端并行拉取(后台 & 同时跑,完了 wait)
  ( "$RCLONE" cat "$SRC/$path" --offset "$off" --count "$len" --no-check-certificate \
      --retries 5 --low-level-retries 20 > "$srcf" 2>"$WORKDIR_DIAG/d_${seq}.src.log" \
      || { rm -f "$srcf"; echo "$(src_fail_kind "$WORKDIR_DIAG/d_${seq}.src.log") $path" > "$WORKDIR_DIAG/d_${seq}.fail"; \
           echo "::warning:: SRCFAIL seq=$seq off=$off (源端 ${SRC}:范围读取失败) $path" >&2; } ) &
  local pidsrc=$!
  ( "$RCLONE" cat "$DST/$path" --offset "$off" --count "$len" --no-check-certificate \
      --retries 5 --low-level-retries 20 > "$dstf" 2>"$WORKDIR_DIAG/d_${seq}.dst.log" \
      || { rm -f "$dstf"; echo "DSTFAIL $path" > "$WORKDIR_DIAG/d_${seq}.fail"; \
           echo "::warning:: DSTFAIL seq=$seq off=$off (目标端 ${DST}:范围读取失败,文件/目录可能缺失) $path" >&2; } ) &
  local piddst=$!
  wait "$pidsrc" || true
  wait "$piddst" || true
  # 落盘字节核对(仅在文件存在时统计;失败文件会被 rm 掉,du 返回 0)
  local ss=$(( $(du -b "$srcf" 2>/dev/null | cut -f1) + 0 ))
  printf '%s\tSRC\t%s\t%s\t%s\n' "$seq" "$ss" "$len" "$path" >> "$WORKDIR_DIAG/sizes.tsv"
  if [ "$ss" -gt $(( len + 1048576 )) ]; then  # 超过 len 1MiB 容差 = 疑似全量下载
    echo "::warning::WARN 源端疑似整文件下载 seq=$seq off=$off want=$len got=$ss $path" >&2
  fi
  local ds=$(( $(du -b "$dstf" 2>/dev/null | cut -f1) + 0 ))
  printf '%s\tDST\t%s\t%s\t%s\n' "$seq" "$ds" "$len" "$path" >> "$WORKDIR_DIAG/sizes.tsv"
  if [ "$ds" -gt $(( len + 1048576 )) ]; then
    echo "::warning::WARN 目标端疑似整文件下载 seq=$seq off=$off want=$len got=$ds $path" >&2
  fi
  # 源端落 0 字节而请求 len>0:候选都已过 MIN_SIZE 且 off<=Size-len,合法 Range 读不可能为空,
  # 只能是 CDN 对该范围回了 200-空(断供形态之一)。这不是内容不一致——把它标成失败片,
  # 让本片走 SKIP 而不是 MISMATCH;否则 DEL_MISMATCH 会因源端断供删掉目标端的好文件
  # (2026-10-03 silver-de-04 实测:4 个 MISMATCH 全是源端 got=0/目标端读满,却已发出 delete)。
  if [ "$len" -gt 0 ] && [ "$ss" -eq 0 ] && [ ! -e "$WORKDIR_DIAG/d_${seq}.fail" ]; then
    echo "SRCEMPTY $path" > "$WORKDIR_DIAG/d_${seq}.fail"
    echo "::warning:: SRCEMPTY seq=$seq off=$off want=$len (源端 ${SRC} 返回 0 字节=CDN 断供,按不可用计) $path" >&2
  fi
}
export -f fetch_one src_fail_kind
export RCLONE SRC DST WORKDIR WORKDIR_DIAG WORKDIR_CHUNKS VERBOSE

# ---- 阶段 2 备选: 签直链 + aria2c (FETCH_MODE=aria2) ----
# 动机: 每片起一个 rclone 进程要付三笔固定开销 —— 进程启动、NewFs 的会员等级探测、
# 以及每片重做的"逐级列目录找 ID"(群盘一页 100/200 条,3071 条的目录一次解析要翻十几页)。
# 改成每文件签一次直链(rc 端点 operations/publiclink), 每片只发一个带 Range 的 GET。
# 群盘取链接口只收单个 contentID(2026-10-23 实测: 传数组回"数据格式有误"), 所以签名次数
# 是一轮 50 次/侧的下限, 不会更少。
rcd_start() {
  "$RCLONE" rcd --rc-no-auth --rc-addr "$RCD_ADDR" --config "$RCLONE_CONFIG" \
      --log-file "$WORKDIR_DIAG/rcd.log" --log-level NOTICE &
  RCD_PID=$!
  local i
  for i in $(seq 1 100); do
    if curl -sS -m 2 -o /dev/null "$RCD_ADDR/core/version" 2>/dev/null; then return 0; fi
    if ! kill -0 "$RCD_PID" 2>/dev/null; then
      echo "::error::rcd 进程已退出,签链不可用(见 rcd.log)" >&2
      return 1
    fi
    sleep 0.2
  done
  echo "::error::rcd 20 秒内未就绪(见 rcd.log)" >&2
  return 1
}

# 参数 "SIDE<TAB>path"; 输出 "path<TAB>side<TAB>url|-"
sign_side() {
  local spec="$1" side path url body remote resp i
  side="${spec%%$'\t'*}"
  path="${spec#*$'\t'}"
  if [ "$side" = SRC ]; then remote="$SRC"; else remote="$DST"; fi
  # 路径经 stdin 喂给 jq 做 JSON 转义, 不走 --arg: Windows 上 jq 的 argv 会被
  # 按本地码页转码, 中文路径会变成乱码(2026-10-23 实测, 两端都签不出)。
  # 组好的 body 也必须走文件: curl 的 -d 是 argv, 同样会转码, 同一轮里手工
  # 用 --data-binary @文件 签同一个路径就能成功, 差别只有这一处。
  body=$(printf '{"fs":%s,"remote":%s}' \
    "$(printf '%s' "$remote" | jq -Rs .)" "$(printf '%s' "$path" | jq -Rs .)")
  local bfile
  bfile=$(mktemp "$WORKDIR_DIAG/req.XXXXXX")
  printf '%s' "$body" > "$bfile"
  for i in 1 2; do
    resp=$(curl -sS -m 30 -H 'Content-Type: application/json' --data-binary @"$bfile" \
           "$RCD_ADDR/operations/publiclink" 2>/dev/null || true)
    url=$(printf '%s' "$resp" | jq -r '.url // empty' 2>/dev/null) || url=""
    [ -n "$url" ] && break
    sleep 1
  done
  rm -f "$bfile"
  if [ -z "$url" ]; then
    # 签不出来要留证据: 记下服务端的应答(URL 若出现则只留 host), 否则只有一句"少了条链"
    printf '%s\t%s\t%s\n' "$side" "$path" \
      "$(printf '%s' "$resp" | sed -E 's#(https?://)[^"]+#\1<redacted>#g' | tr '\n' ' ' | cut -c1-200)" \
      >> "$WORKDIR_DIAG/sign.err"
    printf '%s\t%s\t-\n' "$path" "$side"
    return 0
  fi
  # 源端 s3 的 publiclink 签的是源站 host; 内容实际要从 CDN 取, 与 Open 路径同样的 host 改写
  if [ "$side" = SRC ] && [ -n "$SRC_DOWNLOAD_HOST" ] && [ -n "$url" ]; then
    url=$(printf '%s' "$url" | sed -E "s#^(https?://)[^/]+#\1${SRC_DOWNLOAD_HOST}#")
  fi
  printf '%s\t%s\t%s\n' "$path" "$side" "$url"
}
export -f sign_side
export RCD_ADDR SRC_DOWNLOAD_HOST

aria2_fetch() {
  local urls="$WORKDIR_DIAG/urls.tsv" plan_sizes="$WORKDIR_DIAG/plan-sizes.tsv"
  local ain="$WORKDIR_DIAG/aria2.in" path off len seq side suffix url want avail sz got f
  : > "$urls"; : > "$WORKDIR_DIAG/sign.err"; : > "$ARIA2_LOG"
  rcd_start || return 1
  jq -r '.[] | [.Path, (.Size|tostring)] | @tsv' "$FILES_JSON" > "$plan_sizes" 2>/dev/null || : > "$plan_sizes"

  tick "阶段2a 签直链 files=$probed_files sign_jobs=$SIGN_JOBS ..."
  while IFS= read -r p; do printf 'SRC\t%s\nDST\t%s\n' "$p" "$p"; done \
    < <(cut -f1 "$CHUNKS_FILE" | sort -u) \
    | xargs -d '\n' -P "$SIGN_JOBS" -I{} bash -c 'sign_side "$1"' _ {} >> "$urls" 2>/dev/null || true
  tick "阶段2a 完成 签出 $(awk -F'\t' '$3!="-"' "$urls" | wc -l)/$(( probed_files * 2 )) 条, 失败见 sign.err"

  : > "$ain"
  while IFS=$'\t' read -r path off len seq; do
    for side in SRC DST; do
      suffix=$(printf '%s' "$side" | tr 'A-Z' 'a-z')
      url=$(awk -F'\t' -v p="$path" -v s="$side" '$1==p && $2==s {print $3; exit}' "$urls")
      if [ -z "$url" ] || [ "$url" = "-" ]; then
        # 签不出来就是这一端读不到(文件不在/服务端拒), 与 rclone 模式的 SRCFAIL/DSTFAIL 同义
        if [ ! -e "$WORKDIR_DIAG/d_${seq}.fail" ]; then
          if [ "$suffix" = dst ]; then echo "DSTFAIL $path" > "$WORKDIR_DIAG/d_${seq}.fail"
          else echo "SRCFAIL $path" > "$WORKDIR_DIAG/d_${seq}.fail"; fi
        fi
        continue
      fi
      { printf '%s\n' "$url"
        printf '  out=d_%s.%s\n' "$seq" "$suffix"
        printf '  header=Range: bytes=%s-%s\n' "$off" "$(( off + len - 1 ))"
        printf '\n'
      } >> "$ain"
    done
  done < "$CHUNKS_FILE"

  local nreq; nreq=$(grep -c '^https' "$ain" 2>/dev/null || echo 0)
  tick "阶段2b aria2 开始 请求=$nreq jobs=$JOBS deadline=${STAGE2_DEADLINE}s"
  local rc=0
  if [ "$nreq" -gt 0 ]; then
    # aria2 会用 Content-Range 里的总长校验响应区间, 我们对整文件只要一段, 它必判
    # "Invalid range header" 并以 errorCode=8 结束(2026-10-23 实测: 4/4 次, 每片内容
    # 仍正确)。所以这里的成败判据是落盘字节与内容, 不是 aria2 的退出码。
    timeout -k 10 "$STAGE2_DEADLINE" "$ARIA2" -i "$ain" -j "$JOBS" -x1 -s1 -k1M \
      --dir "$WORKDIR_CHUNKS" --max-tries="$ARIA2_TRIES" --retry-wait=2 \
      --timeout="$CHUNK_TIMEOUT" --connect-timeout="$CHUNK_CONNECT_TIMEOUT" \
      --auto-file-renaming=false --allow-overwrite=true --file-allocation=none \
      --console-log-level=warn --summary-interval=0 --download-result=hide \
      --log="$ARIA2_LOG" --log-level=warn >"$WORKDIR_DIAG/aria2.out" 2>&1 || rc=$?
  fi
  kill "$RCD_PID" 2>/dev/null || true
  tick "阶段2b 结束 rc=$rc (0=全部成功, 124=撞墙钟; 8=range 校验,按字节判成败)"

  # 逐片核对落盘字节: 期望值是 min(len, 文件大小-off)。aria2 中途断流可能留下半截文件,
  # 半截若不判失败就会被阶段3当成 MISMATCH, 再经 DEL_MISMATCH 删掉目标端的好文件。
  local nbad=0
  while IFS=$'\t' read -r path off len seq; do
    for side in SRC DST; do
      suffix=$(printf '%s' "$side" | tr 'A-Z' 'a-z')
      f="$WORKDIR_CHUNKS/d_${seq}.${suffix}"
      got=$(( $(du -b "$f" 2>/dev/null | cut -f1) + 0 ))
      sz=$(awk -F'\t' -v p="$path" '$1==p {print $2; exit}' "$plan_sizes")
      want="$len"
      if [ -n "$sz" ]; then
        avail=$(( sz - off ))
        if [ "$avail" -lt "$want" ]; then want="$avail"; fi
      fi
      if [ "$got" -ne "$want" ]; then
        rm -f "$f" "${f}.aria2"
        nbad=$((nbad+1))
        if [ ! -e "$WORKDIR_DIAG/d_${seq}.fail" ]; then
          if [ "$suffix" = dst ]; then echo "DSTFAIL $path" > "$WORKDIR_DIAG/d_${seq}.fail"
          else echo "SRCFAIL $path" > "$WORKDIR_DIAG/d_${seq}.fail"; fi
        fi
      else
        # aria2 因 range 总长校验失败会留下 .aria2 边车, 但这一段字节已经齐了;
        # 边车清掉, 不据此判失败(真正的半截文件由上面的字节比对兜住)。
        rm -f "${f}.aria2"
        if [ "$got" -gt $(( len + 1048576 )) ]; then
          echo "::warning::WARN ${side} 疑似整文件下载 seq=$seq want=$len got=$got $path" >&2
        fi
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$seq" "$side" "$got" "$len" "$path" >> "$WORKDIR_DIAG/sizes.tsv"
    done
  done < "$CHUNKS_FILE"
  tick "阶段2c 字节核对完成 不合格片=$nbad"
  # aria2 的日志里带完整预签名 URL(含签名参数), 直接进 artifact 就是泄凭据;
  # 只把查询串剥掉的版本放进 diag 供诊断。
  if [ -f "$ARIA2_LOG" ]; then
    sed -E 's#(https?://[^ /]+)[^ ]*#\1<query stripped>#g' "$ARIA2_LOG" > "$WORKDIR_DIAG/aria2.log" 2>/dev/null || true
  fi
}


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
case "$FETCH_MODE" in
  rclone) run_pool "$CHUNKS_FILE" "$JOBS" ;;
  aria2)
    if ! aria2_fetch; then
      echo "::error::aria2 取数层不可用(见上方告警与 rcd.log/aria2.log)" >&2
      exit 1
    fi
    ;;
  *) echo "::error::未知 FETCH_MODE: $FETCH_MODE (只支持 rclone|aria2)" >&2; exit 2 ;;
esac
tick "阶段2完成 全部 ${total_chunks} 片已双端拉取"

# 检查拉取失败的分片
# 用文件数统计而非 wc -l 行数——两端都失败时 SRCFAIL/DSTFAIL 覆盖写入,文件仍只算 1 片
fail_files=$(find "$WORKDIR_DIAG" -name 'd_*.fail' 2>/dev/null | wc -l || true)
if [ "$fail_files" -gt 0 ]; then
  echo "::warning:: $fail_files 个分片拉取失败(源或目标),相关比对将判 SKIP" >&2
else
  rm -f "$WORKDIR_DIAG"/*.fail
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
  local srcf="$WORKDIR_CHUNKS/d_${seq}.src" dstf="$WORKDIR_CHUNKS/d_${seq}.dst"
  if [ -f "$WORKDIR_DIAG/d_${seq}.fail" ]; then
    # 按拉取失败的形态分别计数,聚合口径见阶段3末尾。
    local kind; kind=$(head -1 "$WORKDIR_DIAG/d_${seq}.fail" 2>/dev/null)
    case "$kind" in
      SRCEMPTY*)  echo "SKIP(src_empty) $path";  echo "SKIP(src_empty) $path" >&2 ;;
      SRCNONAME*) echo "SKIP(no_such_dir) $path"; echo "SKIP(no_such_dir) $path" >&2 ;;
      *)          echo "SKIP(file_fail) $path";  echo "SKIP(file_fail) $path" >&2 ;;
    esac
    return 0
  fi
  local a b
  a=$(md5sum "$srcf" 2>/dev/null | awk '{print $1}')
  b=$(md5sum "$dstf" 2>/dev/null | awk '{print $1}')
  if [ -z "$a" ] || [ -z "$b" ]; then
    echo "SKIP(md5_empty) $path"
    echo "SKIP(md5_empty) $path" >&2
  elif [ "$a" = "$b" ]; then
    echo "OK $path"
  else
    echo "MISMATCH $path"
    echo "MISMATCH $path" >&2
  fi
}
export -f compare_one
export WORKDIR WORKDIR_DIAG WORKDIR_CHUNKS

# 并行比对, 结果写结果文件, 再聚合到文件级
RESULT="$WORKDIR_DIAG/result.txt"
: > "$RESULT"
i=0
while IFS= read -r l; do
  compare_one "$l" >> "$RESULT" &
  i=$((i+1))
  if [ $((i % CHECKERS)) -eq 0 ]; then wait; i=0; fi
done < "$CHUNKS_FILE"
wait

# ---- 聚合到文件级 ----
tot_mism=0; tot_ok=0; tot_skip=0; skip_ff=0; skip_me=0; skip_se=0; skip_nm=0
declare -A filestat
: > "$WORKDIR_DIAG/mismatch_files.txt"
# 用第一个空格做分割点——path 可能含空格(如"英特尔® XTU/xxx.iso"),IFS= 只读第一个空格会截断
while IFS= read -r line; do
  [ -z "$line" ] && continue                      # 空行跳过
  cond="${line%% *}"                              # 第一个空格前的结果类型
  path="${line#* }"                               # 第一个空格后的完整路径
  case "$cond" in
    MISMATCH)          tot_mism=$((tot_mism+1)); filestat["$path"]="MISMATCH"; echo "$path" >> "$WORKDIR_DIAG/mismatch_files.txt" ;;
    SKIP\(file_fail\)) tot_skip=$((tot_skip+1)); skip_ff=$((skip_ff+1)); [ -z "${filestat[$path]+x}" ] && filestat["$path"]="SKIP" ;;
    SKIP\(md5_empty\)) tot_skip=$((tot_skip+1)); skip_me=$((skip_me+1)); [ -z "${filestat[$path]+x}" ] && filestat["$path"]="SKIP" ;;
    SKIP\(src_empty\))   tot_skip=$((tot_skip+1)); skip_se=$((skip_se+1)); [ -z "${filestat[$path]+x}" ] && filestat["$path"]="SKIP" ;;
    SKIP\(no_such_dir\)) tot_skip=$((tot_skip+1)); skip_nm=$((skip_nm+1)); [ -z "${filestat[$path]+x}" ] && filestat["$path"]="SKIP" ;;
    SKIP*)             tot_skip=$((tot_skip+1)); [ -z "${filestat[$path]+x}" ] && filestat["$path"]="SKIP" ;;  # 兜底:裸 SKIP 兼容
    *)                 tot_ok=$((tot_ok+1)) ;;
  esac
done < "$RESULT"

# 交叉验证:阶段2统计的 .fail 文件数 vs 阶段3里所有"该片不可用"的 SKIP 行数
# (file_fail 拉取失败 / src_empty 源端断供 / no_such_dir 敏感词目录,三类都会落 .fail 标记)
unusable=$((skip_ff + skip_se + skip_nm))
cross_ok=1
if [ "$unusable" -ne "$fail_files" ]; then
  echo "::warning::计数不一致:阶段2有 $fail_files 个 .fail 文件,但阶段3只看到 $unusable 个不可用分片(file_fail=$skip_ff src_empty=$skip_se no_such_dir=$skip_nm)" >&2
  cross_ok=0
fi

echo "$RESULT" >&2  # keep
mism_files=0; ok_files=0; skip_files=0
for path in "${!filestat[@]}"; do
  case "${filestat[$path]}" in
    MISMATCH) mism_files=$((mism_files+1)); echo "MISMATCH $path" ;;
    SKIP)     skip_files=$((skip_files+1)); echo "SKIP(file) $path" ;;
  esac
done
# 文件级 OK = 被探测文件 - mismatch 文件 - 被 skip(拉取失败,未真正比对)的文件;
# 之前漏减 skip_files 会把"没验证到"的文件算成 ok,与 chunks_skip 自相矛盾。
ok_files=$(( $(cut -f1 "$CHUNKS_FILE" | sort -u | wc -l) - mism_files - skip_files ))

# DEL_MISMATCH:迁移 verify 自治——把不一致的目标文件删掉,重跑 sync 即重传修复。
# 串行逐个删(失败不影响其他),删除走 rclone deletefile(幂等,文件不存在也成功)。
# 到这里的不一致必然是"两端都读到非空且内容不同":源端 0 字节(CDN 断供)已在阶段2
# 标成 src_empty 走 SKIP,不会触发删除——断供时删目标端等于把好数据交给一个取不到源的地方重建。
# 注:SRC/DST/RCLONE 已在 fetch 段 export,此处(主进程)直接可见。
if [ -n "$DEL_MISMATCH" ] && [ "$mism_files" -gt 0 ]; then
  echo "== DEL_MISMATCH 已开启,删除 $mism_files 个不一致目标文件 ==" >&2
  # mismatch_files.txt 是按**分片**写的,同一文件最多被写 CHUNKS_PER_FILE 次。不去重就会对同一个
  # 对象连发 10 次 deletefile(2026-10-03 de-04 日志里 31 条删除告警就是这么来的)。
  sort -u "$WORKDIR_DIAG/mismatch_files.txt" > "$WORKDIR_DIAG/mismatch_files.uniq"
  d_gone=0; d_still=0; d_lie=0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if "$RCLONE" deletefile --no-check-certificate "$DST/$p" --retries 5 \
       2>"$WORKDIR_DIAG/del.err"; then drc=0; else drc=1; fi
    # 回读确认:联通盘的删除是异步任务。deletefile 返回 0 而对象仍在原地、以及返回 not found
    # 而对象其实早就不在了,两种都实测过——只看退出码会把这两件事都判反。
    if [ -n "$("$RCLONE" lsf --files-only --no-check-certificate "$DST/$p" 2>/dev/null || true)" ]; then
      d_still=$((d_still+1))
      echo "::warning::删除后回读仍在目标端(deletefile rc=$drc): $p" >&2
    else
      d_gone=$((d_gone+1))
      [ "$drc" -ne 0 ] && d_lie=$((d_lie+1))
      echo "  deleted: $p (回读已消失, deletefile rc=$drc)" >&2
    fi
  done < "$WORKDIR_DIAG/mismatch_files.uniq"
  echo "== DEL_MISMATCH 结果: 回读已消失=$d_gone 仍存在=$d_still (退出码与回读不一致=$d_lie) ==" >&2
fi

tick "阶段3完成"
echo "=== probe done: files_ok=$ok_files files_mismatch=$mism_files files_skip=$skip_files chunks_total=$total_chunks chunks_ok=$tot_ok chunks_mismatch=$tot_mism chunks_skip=$tot_skip (skip_ff=$skip_ff skip_me=$skip_me skip_src_empty=$skip_se skip_no_such_dir=$skip_nm fail_files=$fail_files cross_ok=$cross_ok) ===" >&2

# 可验证比例:两端都拿到非空内容并真正比过的文件占比。比例过低时结论只是"没验证到",
# 不能当成"内容一致"——源端断供(CDN 200-空)会让整桶都落到 skip 里。
verified_files=$((probed_files - mism_files - skip_files))
if [ "$probed_files" -gt 0 ] && [ $(( verified_files * 100 )) -lt $(( probed_files * 50 )) ]; then
  echo "::warning::verdict=INCONCLUSIVE 可验证文件仅 $verified_files/$probed_files (<50%),源端不可用 src_empty=$skip_se 敏感词目录=$skip_nm;本结论不代表内容一致" >&2
else
  echo "verdict=OK verified=$verified_files/$probed_files" >&2
fi

# 保留诊断文件供 artifact(字节核对 sizes.tsv / lsjson.vv.log / 各片 rclone 日志 / result)
# WORKDIR 默认保留分片本体供取证(chunks artifact);设 CLEANUP=1 时删除本体(含 diag 里的分片计划)。
if [ "${CLEANUP:-}" = "1" ]; then
  find "$WORKDIR_CHUNKS" -name 'd_*.src' -o -name 'd_*.dst' | xargs -r rm -f
  rm -f "$WORKDIR_DIAG/chunks.0"
fi
echo "WORKDIR_ARTIFACT=$WORKDIR" >&2

# 退出语义: 仅发现不一致(MISMATCH,且已 DEL_MISMATCH 删除目标)才非 0;
# 拉取失败(SKIP)不致命——目标端目录缺失等 read 失败由 sync 阶段 size-only 兜底。
[ "$tot_mism" -eq 0 ]