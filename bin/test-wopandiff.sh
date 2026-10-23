#!/bin/bash
# bin/wopandiff.sh 的自检：每条吸收规则都要能失败。
# 由 Verify 步在用它之前跑一遍，所以这里任何一条红都意味着那条链的判据不可信。
# 只依赖 bash/grep/sed/awk/mktemp，不发网络请求。
set -u
S=$(cd "$(dirname "$0")" && pwd)/wopandiff.sh
[ -x "$S" ] || [ -f "$S" ] || { echo "ABORT: 找不到 $S"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ck() { # ck <名字> <期望无法解释数> <期望退出码> <copy日志> <check日志>
  local name="$1" wantn="$2" wantrc="$3" c="$4" k="$5" out rc got
  out=$(bash "$S" "$c" "$k" 1 2>&1); rc=$?
  got=$(printf '%s' "$out" | sed -n 's/.*无法解释=\([0-9]*\).*/\1/p' | head -1)
  if [ "$got" = "$wantn" ] && [ "$rc" = "$wantrc" ]; then
    echo "PASS  $name (unexp=$got rc=$rc)"; pass=$((pass+1))
  else
    echo "FAIL  $name 期望 unexp=$wantn rc=$wantrc 实得 unexp=${got:-?} rc=$rc"
    printf '%s\n' "$out" | head -2
    fail=$((fail+1))
  fi
}
TS='2026/10/23 13:47:11'
mkr() { printf '%s ERROR : %s: Failed to copy: failed to make directory: wopan: x RSP_CODE=%s\n' "$TS" "$1" "$2"; }
mkm() { printf '%s ERROR : %s: file not in wopan root %s\n' "$TS" "$1" "'s3-bak/bucket'"; }
mke() { printf "%s ERROR : %s: Failed to copy: can't upload empty files to this remote\n" "$TS" "$1"; }

mkr "a/b c/f1.txt" 4444 > "$T/c1";  mkm "a/b c/f1.txt" > "$T/k1";  ck "目录名被拒：吸收其下缺失" 0 0 "$T/c1" "$T/k1"
mkr "a/b c/f1.txt" 4444 > "$T/c2";  mkm "a/b c2/g.txt" > "$T/k2"; ck "兄弟目录不被前缀吃掉" 1 1 "$T/c2" "$T/k2"
mke "d/e/empty.key" > "$T/c3";      mkm "d/e/empty.key" > "$T/k3"; ck "空文件：按精确路径吸收" 0 0 "$T/c3" "$T/k3"
mke "d/e/empty.key" > "$T/c4";      mkm "d/e/real.bin" > "$T/k4";  ck "空文件不连带整目录" 1 1 "$T/c4" "$T/k4"
mkr "p/q: r/SKIP me/f.txt" 1009 > "$T/c5"; mkm "p/q: r/SKIP me/f.txt" > "$T/k5"; ck "路径含冒号与 SKIP 字面量" 0 0 "$T/c5" "$T/k5"
mkr "u/v/f.txt" 9999 > "$T/c6";     mkm "u/v/f.txt" > "$T/k6";     ck "9999 系统异常不吸收" 1 1 "$T/c6" "$T/k6"
mkr "u/v/f.txt" 2001 > "$T/c7";                                   ck "2001 空间满不吸收" 1 1 "$T/c7" "$T/k6"
mkr "f.txt" 4444 > "$T/c8";         mkm "g.txt" > "$T/k8";         ck "根下路径不按空前缀全吸" 1 1 "$T/c8" "$T/k8"
mkr "a/b c/f1.txt" 4444 > "$T/c9";  { printf '%s ERROR : No common hash found - not using a hash for checks\n' "$TS"; mkm "a/b c/f1.txt"; } > "$T/k9"
ck "check 里其它 ERROR 只报数" 0 0 "$T/c9" "$T/k9"
mkr "甲/乙 丙/文件.txt" 4444 > "$T/c10"; mkm "甲/乙 丙/文件.txt" > "$T/k10"; ck "中文与空格路径" 0 0 "$T/c10" "$T/k10"
mkr "a/b/f1.txt" 4444 > "$T/c11";   mkm "z/a/b/x.txt" > "$T/k11";   ck "前缀只认开头，不认中间" 1 1 "$T/c11" "$T/k11"

echo "---- wopandiff 自检：PASS=$pass FAIL=$fail ----"
[ "$fail" = "0" ]
