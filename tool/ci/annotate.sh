#!/usr/bin/env bash
# 把一段日志的末尾几行发成**工作流注解**（workflow annotation）。
#
# 为什么要有它：这条流水线跑在 GitHub 上，而 GitHub 对**没登录**的访问会隐藏完整
# 日志（页面上那句 “Sign in for the full log view”），API 拿日志也一律 403。注解
# 不一样 —— 它挂在 check run 上，是**公开数据**，匿名就能读：
#
#     curl -s https://api.github.com/repos/<owner>/<repo>/check-runs/<id>/annotations
#
# 2026-10-14 的前两轮就是吃了这个亏：静态检查那 156 条报错、以及全量用例里挂掉的
# 那 1 条，都只能靠人工登录 + 复制才看得到（后者到现在还不知道是哪条）。这个脚本
# 让「红了」和「为什么红」同时出现在一个不用登录的地方。
#
# 用法：
#     bash tool/ci/annotate.sh <标题> <日志文件> [末尾行数=30]
#
# 注意：GitHub 每个步骤最多接受 10 条注解，所以这里**只发一条** —— 把末尾多行折进
# 同一条正文里（注解正文里的换行必须写成 %0A，`%` 本身要写成 %25）。故意不引用
# 日志里任何内容做判断：它只负责搬运，谁调用它谁决定标题。
set -u

title="${1:?用法: annotate.sh <标题> <日志文件> [末尾行数]}"
file="${2:?缺少日志文件}"
lines="${3:-30}"

if [ ! -f "$file" ]; then
  echo "::error title=${title}::（注解脚本找不到日志文件：${file}）"
  exit 0
fi

# `sed` 先把 `%` 转义掉、顺手去掉 CR，`awk` 再把换行折成 %0A。
msg="$(
  tail -n "$lines" "$file" |
    sed -e 's/%/%25/g' -e 's/\r$//' |
    awk 'BEGIN { first = 1 } { if (!first) printf "%%0A"; printf "%s", $0; first = 0 }'
)"

[ -n "$msg" ] || msg="（日志是空的 —— 说明失败发生在写出任何输出之前）"

# 这一步自己永远算成功：它的职责是把话说出来，不是判断成败。
echo "::error title=${title}::${msg}"
exit 0
