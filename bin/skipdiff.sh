#!/usr/bin/env bash
# 校验结果的"真缺失"判定。
#
# 原来这条链路把预期跳过名单直接喂给 `rclone check --exclude-from`，那是 glob 语义：
# 路径里的 `:` 会被执行器早期的 sed 截错，不配对的 `[ ] { }` 会让整个 check 起不来
# (实测 CRITICAL: mismatched '[' and ']')，`--exclude-from` 还会丢掉以 `#`/`;` 开头的
# 行并 TrimSpace。名单一旦歪掉，要么误排真文件(静默假绿)，要么把校验步本身弄挂。
#
# 这里改成纯字符串相减：check 不带 exclude 照跑，从 check.log 取"目标端缺失"的
# 路径集合，再用 copy.log 里的 SKIP 名单去覆盖，剩下的才是真缺失。
#
# usage: skipdiff.sh <copy-log 或 -> <check-log>
#   copy-log 传 - 表示本轮没有 copy 阶段(独立 verify 模式)，此时名单由调用方
#   预先写在 $EXPECTED_SKIP 指向的文件里。
set -u
copylog=${1:?usage: skipdiff.sh <copy-log|-> <check-log> [check-rc]}
checklog=${2:?usage: skipdiff.sh <copy-log|-> <check-log> [check-rc]}
chkrc=${3:-0}
expected=${EXPECTED_SKIP:-}

EXPECT=/tmp/skipdiff-expected.txt
MISSING=/tmp/skipdiff-missing.txt
RESID=/tmp/skipdiff-residual.txt

if [ "$copylog" != "-" ]; then
  # 每类永久拒绝的文案尾巴是固定的，所以从"SKIP "起、贪婪到那一个尾巴为止。
  # 贪婪在这里是安全的：一行只有一条尾巴，而路径里哪怕含 "SKIP " 或冒号也不会
  # 让左起第一个 "SKIP " 变位。
  grep -aoE 'SKIP .*: (the server rejects a name in this path|the server rejects this file name|this remote cannot store empty files|[0-9]+ bytes exceeds the member single-file upload limit)' "$copylog" 2>/dev/null \
    | sed -E 's/^SKIP //; s/: (the server rejects|this remote cannot store|[0-9]+ bytes exceeds).*//' \
    | sort -u > "$EXPECT"
elif [ -n "$expected" ] && [ -f "$expected" ]; then
  sort -u "$expected" > "$EXPECT"
else
  : > "$EXPECT"
fi

grep -aoE 'ERROR : .*: file not in ' "$checklog" 2>/dev/null \
  | sed -E 's/^ERROR : //; s/: file not in $//' \
  | sort -u > "$MISSING"

# 名单里以 / 结尾的条目代表"这一棵子树都不传"，用前缀匹配；其余按整串相等。
# 名单在 BEGIN 里用 getline 读：awk 的 NR==FNR 惯用法在名单文件为空时会失效，
# 那时第一条"缺失"会被当成名单收下，整个判定静默变绿。
awk -v EF="$EXPECT" '
  BEGIN {
    while ((getline line < EF) > 0) {
      if (line ~ /\/$/) { np++; pref[np] = line } else { ex[line] = 1 }
    }
    close(EF)
  }
  {
    p = $0
    if (p in ex) next
    for (i = 1; i <= np; i++) if (substr(p, 1, length(pref[i])) == pref[i]) next
    print p
  }
' "$MISSING" > "$RESID" || { echo "::error::skipdiff 判定本身失败(awk 非 0)，按红处理"; exit 1; }

# 其它形状的 ERROR(不带 "file not in")也可能是真故障，单独数出来，别吞掉。
OTHER=$(grep -acE ' ERROR : ' "$checklog" 2>/dev/null)
OTHER=$((${OTHER:-0} - $(wc -l < "$MISSING")))
BENIGN=$(grep -acE ' ERROR : No common hash found' "$checklog" 2>/dev/null)
OTHER=$((OTHER - ${BENIGN:-0}))
[ "$OTHER" -lt 0 ] && OTHER=0

echo "skipdiff: 预期跳过 $(wc -l < "$EXPECT") 条 / 目标缺失 $(wc -l < "$MISSING") 条 / 无法解释 $(wc -l < "$RESID") 条 / 其它 ERROR $OTHER 条"
if [ -s "$RESID" ]; then
  echo "::group::无法用 SKIP 名单解释的缺失(前 50 条)"
  head -50 "$RESID"
  echo "::endgroup::"
fi
if [ "$OTHER" -gt 0 ]; then
  echo "::group::check 报出的其它 ERROR(前 20 条)"
  grep -aE ' ERROR : ' "$checklog" | grep -av 'file not in \|No common hash found' | head -20
  echo "::endgroup::"
fi

if [ "$chkrc" != "0" ] && [ ! -s "$MISSING" ]; then
  # check 非 0 却一条"目标缺失"都报不出来：那是建 fs/列目录这类整步故障，
  # 不是名单能解释的差别。放行就等于把基础设施故障读成"全部预期跳过"。
  echo "::error::rclone check 退出码 $chkrc 但没有任何缺失条目，这是整步故障而非预期跳过"
  exit 1
fi

if [ -s "$RESID" ] || [ "$OTHER" -gt 0 ]; then
  echo "::error::目标端存在 $(wc -l < "$RESID") 个无法解释的缺失、$OTHER 条其它错误；这不是"明确不传"的那批"
  exit 1
fi
exit 0
