#!/usr/bin/env bash
#
# resmon.sh — 迁移运行期资源+吞吐采样器(后台常驻)
#
# 每 5s 输出一行到 stderr(RESMON 前缀,直接进 GH step 日志)+ 追加到 /tmp/resmon.log(artifact)。
# 采样内容:
#   rclone_RSS          rclone 进程 RSS(MiB, 多实例求和)
#   Mem_used/Mem_avail  系统内存(单位 MiB)
#   tmp_avail             /tmp 可用(单位 GiB)
#   net_dl/net_ul        最近5s 网络 下行/上行 吞吐(MB/s)= /proc/net/dev 各非 lo 接口累计字节差时均值
#   wg_dl/wg_ul          WARP 隧道接口 wg0 单独的上/下行吞吐(存在才出现,避免混进总带宽)
#
# 用途: 定位迁移大文件时到底是内存(streams 缓冲)还是磁盘(临时文件/写盘)还是带宽(含 WARP)顶住。

set -euo pipefail

LOG="${RESMON_LOG:-/tmp/resmon.log}"
# 检测 WARP 隧道接口是否存在
WG=$(awk '$1=="wg0:"{print 1; exit}' /proc/net/dev 2>/dev/null || echo 0)

PREV_T=$(date +%s); PREV_RX=0; PREV_TX=0; PREV_RG=0; PREV_TG=0
while :; do
  # 每个非 lo 接口的 rx/tx 字节;wg0 单独计数
  read -r rxb txb rg tg < <(awk 'NR>2{gsub(":","",$1); if($1!="lo"){r+=$2; t+=$10; if($1=="wg0"){wg_r+=$2; wg_t+=$10}}} END{printf "%d %d %d %d", r, t, wg_r, wg_t}' /proc/net/dev 2>/dev/null || printf '%s' '0 0 0 0')

  now=$(date +%s); dt=$((now - PREV_T)); [ "$dt" -lt 1 ] && dt=1

  rss=$(ps -C rclone -o rss= 2>/dev/null | awk '{s+=$1} END{if(s) printf "rclone_RSS=%dM ", int(s/1024)}')
  mem=$(free -m | awk '/Mem:/{printf "Mem_used=%dM Mem_avail=%dM ", $3, $7}')
  disk=$(df -B1 /tmp | awk 'NR==2{printf "tmp_avail=%dG ", int($4/2^30)}')
  dl=$(( (rxb - PREV_RX) / 1048576 / dt ))
  ul=$(( (txb - PREV_TX) / 1048576 / dt ))
  wgs=""
  if [ "$WG" = "1" ]; then
    wgs="wg_dl=$(( (rg - PREV_RG) / 1048576 / dt ))MB/s wg_ul=$(( (tg - PREV_TG) / 1048576 / dt ))MB/s"
  fi

  L="$(date +%T) ${rss}${mem}${disk}net_dl=${dl}MB/s net_ul=${ul}MB/s ${wgs}"
  echo "$L" >> "$LOG"
  echo "RESMON $L" >&2

  PREV_T=$now; PREV_RX=$rxb; PREV_TX=$txb; PREV_RG=$rg; PREV_TG=$tg
  sleep 5
done