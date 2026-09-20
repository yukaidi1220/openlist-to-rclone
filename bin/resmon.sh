#!/usr/bin/env bash
#
# resmon.sh — 迁移运行期资源+吞吐采样器(后台常驻)
#
# 每 5s 输出一行到 stderr(RESMON 前缀,直接进 GH step 日志)+ 追加到 /tmp/resmon.log(artifact)。
# 采样内容:
#   rclone_RSS           rclone 进程 RSS(MiB, 多实例求和)
#   Mem_used/Mem_avail   系统内存(MiB)
#   tmp_avail              /tmp 可用(GiB)
#   cpu                   最近5s CPU 总使用率(%)= /proc/stat 忙态增量/总量增量
#   disk_read/disk_write  承载 / 的整盘 最近5s 读写吞吐(MB/s)= /proc/diskstats 扇区增量×512
#   net_dl/net_ul         最近5s 网络 下行/上行 吞吐(MB/s)= /proc/net/dev 非 lo 接口字节差
#   wg_dl/wg_ul          WARP 隧道接口 wg0 单列吞吐(存在才出现)
#
# 用途: 定位大文件迁移到底被 内存(streams缓冲) / 磁盘(写临时文件跟不上→缓冲堆积) /
#        CPU(哈希校验) / 带宽(含WARP) 哪个顶住。rclone_RSS 爬升但 disk_write 低 ⇒ 磁盘写盘跟不上。

set -euo pipefail

LOG="${RESMON_LOG:-/tmp/resmon.log}"
# 是否启用 WARP 隧道
WG=$(awk '$1=="wg0:"{print 1; exit}' /proc/net/dev 2>/dev/null || echo 0)
# 承载 / 的整盘设备名(去掉分区号):/dev/nvme0n1p1 → nvme0n1
DISKDEV=$(findmnt -no SOURCE / 2>/dev/null | sed -E 's#^/dev/##; s/[0-9]+$//; s/p$//' || true)

# 上一拍状态(CPU 忙idle、磁盘字节、网络字节、时间)
PREV_T=$(date +%s)
PREV_CPUTOT=0; PREV_CPUIDLE=0
PREV_DKR=0; PREV_DKW=0
PREV_RX=0; PREV_TX=0; PREV_RG=0; PREV_TG=0

while :; do
  now=$(date +%s); dt=$((now - PREV_T)); if [ "$dt" -lt 1 ]; then dt=1; fi

  # CPU: /proc/stat 第1行, 前8字段和=总, 第5字段=idle
  if [ -r /proc/stat ]; then
    ctot=0; cidle=0
    read -r ctot cidle < <(awk 'NR==1{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5}' /proc/stat)
    dc=$((ctot - PREV_CPUTOT)); if [ "$dc" -lt 1 ]; then dc=1; fi
    busy=$(( (ctot - cidle) - (PREV_CPUTOT - PREV_CPUIDLE) )); if [ "$busy" -lt 0 ]; then busy=0; fi
    cpuuf="cpu=$(( busy * 100 / dc ))% "
    PREV_CPUTOT=$ctot; PREV_CPUIDLE=$cidle
  else cpuuf="cpu=n/a "; fi

  # 磁盘: 承载 / 的整盘读写字节(扇区×512)
  if [ -n "$DISKDEV" ] && [ -r /proc/diskstats ]; then
    dkr=0; dkw=0
    read -r dkr dkw < <(awk -v d="$DISKDEV" 'END{print r, w} $3==d{r=$6*512; w=$10*512}' /proc/diskstats)
    dr=$(( (${dkr:-0} - PREV_DKR) / 1048576 / dt )); if [ "$dr" -lt 0 ]; then dr=0; fi
    dw=$(( (${dkw:-0} - PREV_DKW) / 1048576 / dt )); if [ "$dw" -lt 0 ]; then dw=0; fi
    diskuf="disk_read=${dr}MB/s disk_write=${dw}MB/s "
    PREV_DKR=${dkr:-0}; PREV_DKW=${dkw:-0}
  else diskuf="disk=n/a "; fi

  # 网络: 非 lo 接口 rx/tx 字节增量; wg0 单列
  read -r rxb txb rg tg < <(awk 'NR>2{gsub(":","",$1); if($1!="lo"){r+=$2; t+=$10; if($1=="wg0"){wg_r+=$2; wg_t+=$10}}} END{printf "%d %d %d %d\n", r, t, wg_r, wg_t}' /proc/net/dev 2>/dev/null || printf '%s\n' '0 0 0 0')
  dl=$(( (rxb - PREV_RX) / 1048576 / dt )); if [ "$dl" -lt 0 ]; then dl=0; fi
  ul=$(( (txb - PREV_TX) / 1048576 / dt )); if [ "$ul" -lt 0 ]; then ul=0; fi
  wgs=""
  if [ "$WG" = "1" ]; then
    wgs="wg_dl=$(( (rg - PREV_RG) / 1048576 / dt ))MB/s wg_ul=$(( (tg - PREV_TG) / 1048576 / dt ))MB/s"
  fi

  # 进程/内存/文件系统
  rss=$(ps -C rclone -o rss= 2>/dev/null | awk '{s+=$1} END{if(s) printf "rclone_RSS=%dM ", int(s/1024)}' || true)
  mem=$(free -m | awk '/Mem:/{printf "Mem_used=%dM Mem_avail=%dM ", $3, $7}' || true)
  disk=$(df -B1 /tmp | awk 'NR==2{printf "tmp_avail=%dG ", int($4/2^30)}' || true)

  L="$(date +%T) ${cpuuf}${mem}${rss}${disk}${diskuf}net_dl=${dl}MB/s net_ul=${ul}MB/s ${wgs}"
  echo "$L" >> "$LOG"
  echo "RESMON $L" >&2

  PREV_T=$now; PREV_CPUTOT=${ctot:-0}; PREV_CPUIDLE=${cidle:-0}; PREV_DKR=${dkr:-0}; PREV_DKW=${dkw:-0}
  PREV_RX=$rxb; PREV_TX=$txb; PREV_RG=$rg; PREV_TG=$tg
  sleep 5
done