#!/usr/bin/env bash
# skipdiff.sh 的自测：每条臂都给"期望判定"，其中必须有一条会红。
# 用途是防止这类静默变绿：名单为空时把全部缺失当成已覆盖、判定脚本自己挂掉、
# 以及 check 非 0 却一条缺失都报不出来(那是整步故障，不是"明确不传")。
# 老做法(--exclude-from + 首个冒号取词)的实测失真：a3/a5 两类名字取词就歪，
# a4/a6 两类是 glob 与 --exclude-from 那侧的失真(前者让整个 check CRITICAL 起不来，
# 后者把行当注释丢掉)。
set -u
cd "$(dirname "$0")/.." || exit 1
S=bin/skipdiff.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

mk() { # $1=臂名 $2=缺失路径 $3=SKIP 名单路径(空=不给名单) $4=期望 $5=check 退出码
  d=$T/$1; mkdir -p "$d"
  if [ -n "$2" ]; then
    printf '2026-10-21 16:13:42 ERROR : %s: file not in yun139 root '"'"'s3-bak/x'"'"' (group 1)\n' "$2" > "$d/check.log"
  else
    : > "$d/check.log"
  fi
  if [ -n "$3" ]; then
    printf '2026-10-21 16:12:29 NOTICE: yun139 root: SKIP %s: the server rejects a name in this path as a sensitive word (1909011520); skipping the subtree\n' "$3" > "$d/copy.log"
  else
    : > "$d/copy.log"
  fi
  bash $S "$d/copy.log" "$d/check.log" "${5:-0}" > "$d/out" 2>&1; rc=$?
  got=红; [ "$rc" = "0" ] && got=绿
  if [ "$got" != "$4" ]; then fails=$((fails+1)); echo "FAIL $1: 期望=$4 实测=$got(exit=$rc)"; sed 's/^/      /' "$d/out"; else
    echo "ok   $1: $got  $(head -1 "$d/out")"
  fi
}

# 能红的那条：没有名单，任何缺失都必须判红
mk a1_noskip        'dir/x.toml'                       ''                              红
# 祖先目录整棵被拒：以 / 结尾的名单条目按前缀覆盖
mk a2_parent       'blocked-name/BeeServer/config/x.toml' 'blocked-name/BeeServer/config/' 绿
# 名字里带冒号：老 sed 会截成 a/b，进而精确误排一个同名真文件
mk a3_colon        'a/b:c/x.toml'                     'a/b:c/'                        绿
# 名字里带不配对的中括号：老做法让 rclone check 直接 CRITICAL 起不来
mk a4_bracket      'bad[br/x.toml'                    'bad[br/'                       绿
# 路径里含字面量 "SKIP "：贪婪取最后一个会取到 me/，剩下的真缺失就被误排
mk a5_inner        'logs/SKIP me/x.toml'              'logs/SKIP me/'                 绿
# 名字以 # 开头：--exclude-from 会把这行当注释丢掉
mk a6_hash         '#tag/x.toml'                      '#tag/'                         绿
# 不以 / 结尾的条目是整串相等，不得顺带前缀覆盖同名兄弟文件：
# 这一条专门守"把名单一律当目录前缀匹配"那类放宽
mk a10_exact_only  'report.csv.bak'                   'report.csv'                    红
# check 非 0 却一条缺失都没有：整步故障，不许读成"全部预期跳过"
mk a7_no_missing   ''                                 ''                              红 1
# check 报的不是缺失而是别的错误：必须数进"其它 ERROR"
mk a8_other_error  ''                                 ''                              红 1

d=$T/a8b; mkdir -p "$d"; : > "$d/copy.log"
printf '2026-10-21 16:13:42 ERROR : Failed to create file system for "yun139:": bad token\n' > "$d/check.log"
bash $S "$d/copy.log" "$d/check.log" 1 > "$d/out" 2>&1; rc=$?
got=红; [ "$rc" = "0" ] && got=绿
[ "$got" = 红 ] && echo "ok   a8b_fs_init_failure: 红" || { echo "FAIL a8b_fs_init_failure"; fails=$((fails+1)); }

# 名单盖住全部缺失且 rc 非 0：这正是本轮想要的形状
d=$T/a9; mkdir -p "$d"
printf '2026-10-21 16:12:29 NOTICE: r: SKIP dd/ sub/: the server rejects a name in this path as a sensitive word (1909011520); skipping the subtree\n' > "$d/copy.log"
printf '2026-10-21 16:13:42 ERROR : dd/ sub/x.toml: file not in yun139 root\n' > "$d/check.log"
bash $S "$d/copy.log" "$d/check.log" 1 > "$d/out" 2>&1; rc=$?
got=红; [ "$rc" = "0" ] && got=绿
[ "$got" = 绿 ] && echo "ok   a9_all_covered: 绿" || { echo "FAIL a9_all_covered"; fails=$((fails+1)); }

echo "== 不符期望的臂数 = $fails"
[ "$fails" = "0" ]
