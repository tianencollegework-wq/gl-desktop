#!/usr/bin/env bash
# 把一段日志的**失败现场**发成工作流注解（workflow annotation）。
#
# 为什么要有它：这条流水线跑在 GitHub 上，而 GitHub 对**没登录**的访问会隐藏完整
# 日志（页面上那句 “Sign in for the full log view”），API 拿日志也一律 403。注解
# 不一样 —— 它挂在 check run 上，是**公开数据**，匿名就能读：
#
#     curl -s https://api.github.com/repos/<owner>/<repo>/check-runs/<id>/annotations
#
# 2026-10-14 的四轮全吃了这个亏：静态检查那 156 条、跑挂了的那 1 条用例、
# 以及 `flutter build ios` 的报错，全都要人工登录 + 复制才看得到。
#
# ── 为什么不再是「末尾 N 行」──────────────────────────────────────────────
# 第四轮（run #4，commit a9e673f）换成了搬末尾 120 行，结果**一个字都看不到**：
# 那条注解的正文在 `Fetching from https://github.com/SDWebImage/libwebp-Xcod`
# 中间断掉了。机制两条，一起把人坑死：
#
#   1. GitHub 对单条注解的正文有 65535 字节上限，超了**从尾部砍**。真正要看的
#      报错（xcodebuild / 用例堆栈）恰好都在最后，于是被整段丢掉。
#   2. 日志里有**特别长的一行**：Xcode 拉 SwiftPM 依赖时用 `\r` 在原地刷进度，
#      上百次刷新被折叠成同一行。它自己就能吃掉几万字节的额度，把后面的内容
#      全挤到上限之外。
#
# 所以现在改成：**先挑失败现场**（连行号、连着后面几行一起挑），挑不到才退回
# 「末尾 N 行」；并且每一行截到 300 字、整条正文截到 8000 字（远低于上限），
# 保证「报错本身」永远在正文里，而不是在被砍掉的尾巴上。
#
# 挑的标记里最关键的是 `[E]`：`dart test` 在 CI 上会自动切成 GitHub 专用输出，
# 失败用例那一行长这样 —— **用例名就在这一行里**：
#
#     00:12 +2338 -1: /path/test/xxx_test.dart: 某条用例名 [E]
#
# 用法：
#     bash tool/ci/annotate.sh <标题> <日志文件> [末尾行数=30]
#
# 注意：GitHub 每个步骤最多接受 10 条注解，所以这里**只发一条**（正文里的换行
# 必须写成 %0A，`%` 本身要写成 %25）。故意不引用日志里任何内容做判断：它只负责
# 搬运，谁调用它谁决定标题。
set -u

title="${1:?用法: annotate.sh <标题> <日志文件> [末尾行数]}"
file="${2:?缺少日志文件}"
lines="${3:-30}"

if [ ! -f "$file" ]; then
  echo "::error title=${title}::（注解脚本找不到日志文件：${file}）"
  exit 0
fi

# 失败长什么样 —— **分两级**，这一步很要紧：
#
# 一级（就是失败本身，命中就用它，不再看二级）：
#   dart test    → `::group::❌ <用例名> (failed)`          ← 用例名在这一行里
#                  （CI 上 `dart test` 会自动切 GitHub 专用输出，失败块长这样；
#                    本机用 `GITHUB_ACTIONS=true flutter test …` 能一模一样地复刻）
#                  旧式紧凑输出则是 `00:12 +2338 -1: <文件>: <用例名> [E]`
#   flutter analyze → `   error • 说明 • lib/x.dart:12:3 • undefined_name`
#   Flutter 打 iOS → `Error (Xcode): …` / `Failed to build iOS app`
#   xcodebuild   → `error: …` / `BUILD FAILED` / `The following build commands failed`
#
# 二级（一级没命中才用）：`Exception`、`Expected/Actual` 这类。为什么要分：
# 本仓很多**通过**的用例也会打 `CallMediaException(...)` 这种调试行，全绿的那份日志里
# 一抓一大把 —— 混在一起挑，它们会先把 8000 字额度吃光，把 [E] 那行挤到正文之外。
primary='❌|\[E\]|Error \(Xcode\)|error •|Some tests failed|Failed to build (iOS|macOS) app|BUILD FAILED|The following build commands failed|error: '
secondary='Exception|Expected:|Actual:|warning •|\[SMOKE\]|[0-9]+ tests? failed|Failed to'

# 挑中一行，就把它后面 10 行也带上（堆栈/原因就在那几行里）。最多 60 处命中。
#
# ── 为什么还要往上带 8 行（2026-10-15 加）────────────────────────────────
# 失败点**上面**那几行经常才是「为什么失败」。第十跑（run #5）就是现成的例子：
# 模拟器那条启动自检挂的时候，注解正文里只有一句
#
#     ❌ 从零启动：能跑到登录页 (failed after test completion)
#     Test failed. See exception logs above.
#
# —— 「exception logs above」，而上面那几行正是真正的异常，一条都没搬过来。
# 往下带是为了堆栈，往上带是为了那句「为什么」。只多 8 行：正文总量还是 8000 字
# 上限，往上加太多会把后面真正要看的失败点挤出额度。
pick() { grep -a -n -E -B 8 -A 10 -m 60 "$1" "$file" 2>/dev/null | head -n 300; }

site="$(pick "$primary")"
if [ -n "$site" ]; then
  picked="$site"
  kind="失败现场"
else
  site="$(pick "$secondary")"
  if [ -n "$site" ]; then
    picked="$site"
    kind="失败现场（二级标记）"
  else
    picked="$(tail -n "$lines" "$file")"
    kind="末尾 ${lines} 行（日志里没找到失败标记）"
  fi
fi

# 折成一条：`\r` 只留最后一段（进度条原地刷新）、每行截 300 字、总量截 8000 字。
folded="$(
  printf '%s\n' "$picked" | awk '
    BEGIN { first = 1; total = 0; limit = 8000 }
    {
      line = $0
      n = split(line, parts, "\r")
      line = parts[n]
      if (length(line) > 300) line = substr(line, 1, 300) "…（本行过长已截断）"
      gsub(/%/, "%25", line)
      if (length(line) == 0) next
      if (!first) { printf "%%0A"; total += 4 }
      printf "%s", line
      total += length(line)
      first = 0
      if (total > limit) {
        printf "%%0A……（正文到 8000 字上限：上面是**开头**的现场，完整日志要登录看）"
        exit
      }
    }
  '
)"

[ -n "$folded" ] || folded="（日志是空的 —— 说明失败发生在写出任何输出之前）"

# 这一步自己永远算成功：它的职责是把话说出来，不是判断成败。
echo "::error title=${title}｜${kind}::${folded}"
exit 0
