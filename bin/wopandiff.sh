#!/bin/bash
# wopandiff.sh <copy.log> <check.log> <check_rc>
#
# 把 check 报的"目标缺失"与 copy 阶段里**明确不可传**的集合相减，剩下的一律算真缺失。
# 作用与 bin/skipdiff.sh 相同，但输入形状不同：yun139 后端自己会打 `SKIP <dir>/: ...`，
# wopan 后端不打 SKIP，它的不可传只出现在 copy.log 的 ERROR 行里，有两种可辨形状：
#   1) 目录名被拒：`... ERROR : <dir>/<file>: Failed to copy: failed to make directory: ... RSP_CODE=4444|1009`
#      按**目录**吸收（去掉最后一段、补尾斜杠），尾斜杠前缀匹配，`a/b c/` 不会吸收 `a/b c2/x`。
#   2) 空文件：`... ERROR : <file>: Failed to copy: can't upload empty files to this remote`
#      按**精确路径**吸收（用目录前缀会误伤同目录的真文件）。
# 有意不吸收：9999（系统异常）、130007（名字被占用，瞬时冲突）、2001（空间满）。
# 只把 check.log 的 `... ERROR : <path>: file not in wopan root '...'` 当缺失；别的错误行只报数。
#
# 退出码：无法解释的缺失 > 0 时为 1，否则 0（check 自身非 0 不足以判红，这正是本脚本的目的）。
set -u
copylog=${1:?usage: wopandiff.sh <copy.log> <check.log> <check_rc>}
checklog=${2:?}
rc=${3:-0}
exec awk -v CL="$copylog" -v KL="$checklog" -v RC="$rc" '
# 日志行前面有时间戳，所以不能用 ^ERROR 锚点；一行只有一处 " ERROR : "，贪婪切到它后面即可
function body(l,   t) { t = l; sub(/^.* ERROR : /, "", t); return t }
BEGIN {
  ndir = 0; nfile = 0
  while ((getline l < CL) > 0) {
    if (l ~ /Failed to copy: failed to make directory: .*RSP_CODE=(4444|1009)([^0-9]|$)/) {
      s = body(l)
      sub(/: Failed to copy: failed to make directory:.*$/, "", s)
      d = s
      if (sub(/\/[^\/]*$/, "/", d)) {
        if (!(d in dirs)) { ndir++; dirs[d] = 1 }
      } else {
        if (!(s in files)) { nfile++; files[s] = 1 }
      }
      continue
    }
    if (l ~ /Failed to copy: can.t upload empty files to this remote/) {
      s = body(l)
      sub(/: Failed to copy: can.t upload empty files.*$/, "", s)
      if (!(s in files)) { nfile++; files[s] = 1 }
      continue
    }
  }
  close(CL)
  total = 0; unexp = 0; other = 0
  while ((getline l < KL) > 0) {
    if (l ~ /ERROR : .*: file not in wopan root/) {
      p = body(l)
      sub(/: file not in wopan root .*$/, "", p)
      total++
      if (p in files) continue
      hit = 0
      for (d in dirs) if (substr(p, 1, length(d)) == d) { hit = 1; break }
      if (hit) continue
      unexp++
      if (unexp <= 20) bad[unexp] = p
      continue
    }
    if (l ~ / ERROR : /) other++
  }
  close(KL)
  printf "wopandiff: 可解释 目录=%d 空文件=%d / 目标缺失=%d / 无法解释=%d / 其它ERROR=%d (check rc=%s)\n", \
    ndir + 0, nfile + 0, total + 0, unexp + 0, other + 0, RC
  if (unexp > 0) {
    print "::group::无法用可解释集合吸收的缺失(前 20 条)"
    for (i = 1; i <= unexp && i <= 20; i++) print "  " bad[i]
    print "::endgroup::"
  }
  exit (unexp > 0 ? 1 : 0)
}'
