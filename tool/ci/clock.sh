#!/usr/bin/env bash
# 给一条命令上一道**墙钟**（wall-clock）兜底。
#
# ── 为什么需要它 ────────────────────────────────────────────────────────────
# `flutter test <用例> -d <模拟器>` 在**连接阶段**卡住时，一个字都不打：它得先跟
# 设备上那颗 Dart VM service 握上手，握不上就一直等。用例自己那几道 `withDeadline`
#（`integration_test/ios_call_*.dart`）在这之前根本轮不到执行 —— 那几道防的是
# 「某条设备调用不返回」，防不了「连都没连上」。
#
# 而 GitHub 的步骤级 `timeout-minutes` 砍下来时，步骤里那句 `annotate.sh` 来不及跑
# —— **卡死等于现场全丢**，比红还糟。2026-10-15 那一跑就是这么白烧 20 分钟：
# ②（媒体自检）在连接阶段不动，注解区只留下一句
# `has timed out after 20 minutes`，日志里连一条 `[IOS-MEDIA]` 都没有。
#
# 所以自己上一道更短的墙钟：超时就以非 0 收场（而不是被 GitHub 悄悄砍掉），
# 后面那句 `annotate.sh` 就能把已经拿到的那部分日志贴出来。步骤级
# `timeout-minutes` 仍然留着，当**最外层**兜底。
#
# ── 为什么是这两个分支 ──────────────────────────────────────────────────────
# 先试 GNU 的 `timeout`（本机 Git Bash 就有，方便在 Windows 上验证这一条），
# 没有就用 `perl`：`alarm` 设的定时器**在 exec 之后依然有效**，所以 exec 出去的
# `flutter` 会被 SIGALRM 杀掉，退出码 142（=128+14，看得出来是「被墙钟砍了」）。
# macOS 自带 perl，这条路是稳的。两道都没有就原样跑 —— 宁可没有兜底，也不要
# 因为这个辅助脚本本身让整条链跑不起来。
#
# ⚠️ 本机（Windows 的 Git Bash）只走得到 `timeout` 那一条，而**流水线上走的是
# perl 那一条** —— perl 的 `alarm` 在 Windows 上是空的（本机实测：不砍）。
# 所以 iOS 流水线里有一道「墙钟自检」步骤，真的叫它砍一条 30 秒的命令：
# 削不动就当场红，而不是等真卡死时才发现这道兜底是个摆设。
#
# 用法：
# ```
# bash tool/ci/clock.sh 900 flutter test integration_test/ios_call_media_smoke_test.dart -d "$SIM"
# ```
#
# 本机验证（Git Bash / macOS 都行）：
# ```
# bash tool/ci/clock.sh 1 sleep 5; echo $?   # 1 秒后收场，退出码非 0
# bash tool/ci/clock.sh 5 bash -c 'exit 3'; echo $?   # 原样透传 3
# ```
set -u

if [ "$#" -lt 2 ]; then
  echo "用法：bash tool/ci/clock.sh <秒数> <命令…>" >&2
  exit 2
fi

limit="$1"
shift

if command -v timeout >/dev/null 2>&1; then
  # 124 = GNU timeout 自己的超时码
  exec timeout "$limit" "$@"
fi

if command -v perl >/dev/null 2>&1; then
  exec perl -e 'alarm shift; exec @ARGV' "$limit" "$@"
fi

echo "clock.sh：这台机器既没有 timeout 也没有 perl，这道墙钟上不了，原样跑（退回到步骤级兜底）" >&2
exec "$@"
