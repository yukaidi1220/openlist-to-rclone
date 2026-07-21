#!/usr/bin/env bash
# split_batches.sh - 将 rclone lsf 输出的文件列表按大小分批
# 采用 First-Fit Decreasing 算法，保证每批 ≤ MAX_BYTES
#
# 输入: files_with_size.txt (格式: 大小;路径，由 rclone lsf --format sp --separator ";" 生成)
# 输出: batch_*.txt 文件 + matrix JSON (stdout)
#
# 用法: bash split_batches.sh files_with_size.txt [max_gb]

set -euo pipefail

MAX_GB="${2:-50}"
MAX_BYTES=$((MAX_GB * 1024 * 1024 * 1024))
FILES_FILE="${1:-files_with_size.txt}"

if [[ ! -f "$FILES_FILE" ]]; then
    echo "ERROR: $FILES_FILE not found" >&2
    exit 1
fi

total_files=$(wc -l < "$FILES_FILE")
echo "Processing $total_files files, max batch size: ${MAX_GB} GiB" >&2

# 读入并按大小降序排序（大文件优先分配）
# 过滤掉不符合 "大小;路径" 格式的行（如 rclone 进度输出）
mapfile -t sorted < <(grep -E '^[0-9]+;' "$FILES_FILE" | sort -t';' -k1 -rn)

# batch_remaining[i] = 当前 batch 剩余可用字节
declare -a batch_remaining=()
# batch_bytes[i] = 当前 batch 已使用字节
declare -a batch_bytes=()
# batch_paths[i] = 当前 batch 的文件路径（换行分隔）
declare -a batch_paths=()
batch_count=0

for entry in "${sorted[@]}"; do
    [[ -z "$entry" ]] && continue
    size="${entry%%;*}"
    path="${entry#*;}"
    # size 必须是纯数字；路径中的空格是文件名的一部分，不能删除
    size="${size//[$'\t\r\n ']}"
    path="${path%$'\r'}"

    [[ -z "$size" || -z "$path" ]] && continue

    # First-Fit: 找第一个能放下的 batch
    placed=0
    for ((i = 0; i < batch_count; i++)); do
        if ((batch_remaining[i] >= size)); then
            batch_remaining[i]=$((batch_remaining[i] - size))
            batch_bytes[i]=$((batch_bytes[i] + size))
            batch_paths[$i]+="$path"$'\n'
            placed=1
            break
        fi
    done

    # 放不下，开新 batch
    if ((placed == 0)); then
        if ((size > MAX_BYTES)); then
            echo "WARNING: $path ($size bytes = $(awk "BEGIN{printf \"%.2f\", $size/1024/1024/1024}") GiB) exceeds batch limit,单独一批" >&2
        fi
        batch_remaining[$batch_count]=$((MAX_BYTES - size))
        batch_bytes[$batch_count]=$size
        batch_paths[$batch_count]="$path"$'\n'
        batch_count=$((batch_count + 1))
    fi
done

# 写出 batch 文件 + 构造 matrix JSON
matrix="["
for ((i = 0; i < batch_count; i++)); do
    batch_file="batch_${i}.txt"
    printf '%s' "${batch_paths[$i]}" > "$batch_file"
    count=$(wc -l < "$batch_file" | tr -d ' ')

    total="${batch_bytes[$i]}"

    gb=$(awk "BEGIN{printf \"%.2f\", $total / 1024 / 1024 / 1024}")
    echo "Batch $i: $count files, ${gb} GiB" >&2

    [[ $i -gt 0 ]] && matrix+=","
    matrix+="{\"id\":$i,\"file\":\"$batch_file\",\"count\":$count,\"bytes\":$total}"
done
matrix+="]"

echo "Done: $batch_count batches created" >&2
echo "$matrix"
