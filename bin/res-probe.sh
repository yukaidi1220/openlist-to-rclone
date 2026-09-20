#!/usr/bin/env bash
#
# res-probe.sh — 探测 GitHub Actions runner 的真实资源配置与上限
#
# 目的:
#   1) 摸清 runner 到底有多少内存、多少磁盘、大磁盘挂在哪个挂载点
#      (GitHub 大 runner 可能额外挂 200GB 级磁盘, 位置未必是 / —— 找出它, 供迁移
#       用 TMPDIR 把临时文件指过去, 摆脱 /tmp ~14GiB 上限)。
#   2) 实测内存可用上限: 逐块分配并 touch 真实占用 RSS, 看能撑到多少 GiB 才 OOM,
#      验证"多线程下载 9.6GiB 内存"这种理论值到底可不可信(实证, 不猜)。
#   3) 实测关键挂载点( /tmp 和大容量挂载)的磁盘写吞吐。
#
# 用法:
#   ./res-probe.sh
#   退出码: 0 正常。
#
# 输出全走 stdout, 便于 workflow 直接打日志。

set -euo pipefail

tick() { echo "  [$(date -u +%H:%M:%S)] $*"; }

echo "===== Runner 资源配置探针 ====="
{ . /etc/os-release 2>/dev/null && echo "OS: ${PRETTY_NAME:-未知}"; } || true
echo "ARCH: $(uname -m)"
echo "CPU: $(nproc) 核"
tick "开始"

echo
echo "===== 内存 (free -h) ====="
free -h

echo
echo "===== 全部真实磁盘挂载点 (df -P, 排除 tmpfs) ====="
df -P | awk 'NR==1 || $1!~/^tmpfs/ {printf "  %-28s size=%-8s used=%-8s avail=%-8s use=%s%%\n", $6, $2, $3, $4, $5}'

echo
echo "===== 各挂载点可用容量从大到小 (df -B1) ====="
df -P -B1 | awk 'NR>1 && $2+0>0 {gsub(/%$/,"",$5); printf "%s\t%s\tavail_gb=%.1f\tuse=%d%%\n", $6, $1, $4/1024^3, $5}' \
  | sort -t= -k2,2nr 2>/dev/null || \
  df -P -B1 | awk 'NR>1 && $2+0>0 {printf "%s\tavail_bytes=%s\tuse=%s%%\n", $6, $4, $5}'

echo
echo "===== 大容量磁盘定位 (avail > 5GiB 的挂载点) ====="
BIGMOUNT=$(df -P -B1 | awk 'NR>1 && $4+0>5*1024*1024*1024 {print $6}' | sort | head -1)
echo "最大可用挂载点: ${BIGMOUNT:-无 (都 <5GiB)}"
if [ -n "${BIGMOUNT:-}" ]; then
  [ -w "$BIGMOUNT" ] && echo "  $BIGMOUNT 可写 ✓" || echo "  $BIGMOUNT 不可写 ✗"
fi

echo
echo "===== 实测内存可用上限 (python 渐增 100MiB 块并 touch 真实占页, 到 OOM 前) ====="
python3 - <<'PY'
semi = 104857600          # 100MiB / block
blobs = []
i = 0
try:
    while True:
        b = bytearray(semi)
        # touch 所有页, 让匿名 mmap 真正计入 RSS; block=4096 触碰即可
        step = 4096
        for off in range(0, semi, step):
            b[off] = 1
        blobs.append(b)
        i += 1
        if i % 4 == 0:
            rss_kb = 0
            with open('/proc/self/status') as f:
                for l in f:
                    if l.startswith('VmRSS'):
                        rss_kb = int(l.split()[1]); break
            print(f"  {i:3d} 块 ×100Mi = {i*100:4d}Mi, RSS≈{rss_kb/1024:.0f}Mi", flush=True)
        if i >= 160:
            print("  已达 160 块(16GiB), 主动停止", flush=True)
            break
except MemoryError:
    print(f"  内存耗尽于第 {i} 块 (≈{i*100}Mi)", flush=True)
else:
    rss_kb = 0
    with open('/proc/self/status') as f:
        for l in f:
            if l.startswith('VmRSS'):
                rss_kb = int(l.split()[1]); break
    print(f"  申请完成 {i} 块 (≈{i*100}Mi), RSS≈{rss_kb/1024:.0f}Mi (触发 linux OOM killer 前能保住的大概上限)", flush=True)
PY

echo
echo "===== 磁盘写吞吐实测 (2GiB, conv=fsync) ====="
for d in /tmp $BIGMOUNT; do
  [ -n "$d" ] || continue
  [ -d "$d" ] && [ -w "$d" ] || { echo "  跳过 $d (不可写)"; continue; }
  f="$d/resprobe.$$"
  echo "-- $d --"
  # dd 的 stderr 含吞吐统计
  dd if=/dev/zero of="$f" bs=1M count=2048 conv=fsync 2>&1 | grep -E 'bytes copied|records' || true
  sync
  # 顺带报 df 变化(磁盘真实容量)
  avail_before=$(df -P -B1 "$d" | awk 'NR==2{print $4}')
  # 已删, 这里不再显示差值, 上面 df 表已有容量
  rm -f "$f"
done

echo
tick "探测完成"
echo "=== res-probe done ==="