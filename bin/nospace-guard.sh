#!/usr/bin/env bash
# 账号空间已满是不可恢复的账号态：继续跑只会让剩下每个文件撞同一堵墙，
# 而 --retries 5 还会把整轮再跑 5 遍（实测同一文件 2 分钟一次、共 ~10 次）。
# 命中就点名（涉及文件数、日志行数）并以非零退出；没命中静默通过。
# usage: nospace-guard.sh <rclone-log> [<stage-label>]
set -u
log=${1:?usage: nospace-guard.sh <rclone-log> [stage]}
label=${2:-rclone}
pat='the account has no space left|RSP_CODE=2001'

lines=$(grep -cE "$pat" "$log" 2>/dev/null || true)
[ "${lines:-0}" -eq 0 ] && exit 0

# 失败行形如: "ERROR : <path>: Failed to copy: wopan: the account has no space left: ..."
# 只从 ERROR 行取路径去重；解析不到就退化为 0，不假装知道。
files=$(grep -E "ERROR.*($pat)" "$log" 2>/dev/null \
  | sed -nE 's/^.*ERROR : (.*): Failed to copy:.*$/\1/p' | sort -u | wc -l)

echo "::error::wopan 账号空间已满（RSP_CODE 2001）：${label} 有 ${files} 个文件路径上传失败（日志 ${lines} 行相关记录）；本次未传完，扩容或清理回收站后重跑"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ❌ 空间已满（RSP_CODE 2001）"
    echo ""
    echo "- 阶段：${label}"
    echo "- 未传成功的文件路径：${files}"
    echo "- 日志相关行数：${lines}（含重试轮，--retries 5 会把整轮再跑 5 遍）"
    echo "- 处理：扩容或清理回收站后重跑；重试解决不了这个错误"
    echo "- 备注：rclone 若已支持 \`--wopan-fatal_if_no_space\`（cdn.8 起），它会在第一个 2001 处自行中止；本闸门是兜底"
  } >> "$GITHUB_STEP_SUMMARY"
fi
exit 1
