#!/usr/bin/env bash
# iOS 来电铃声：把应用内那个铃声做成**通知能用的** WAV。
#
# 为什么必须做这个东西（2026-10-15）：
#
# 安卓来电走的是系统铃声（`content://settings/system/ringtone`，见
# `message_notification_presenter.dart` 的 `callRingtoneUri`），用户在锁屏上听到的是
# **自己手机的铃声**。而 iOS 上我们只写了 `presentSound: true` —— 那是**默认提示音**，
# 一声「叮」就没了。真机上表现为「这个软件来电不响」，朋友根本来不及接。
#
# iOS 的规矩（UNNotificationSound）与安卓完全不同，三条都得满足：
#   * 文件必须在 **app 包里**（Xcode 的 Resources 那一相），不能放在 Flutter 的
#     `assets/` 里 —— 那是 Dart 侧的目录，系统看都看不见；
#   * 格式只认 Linear PCM / IMA4 / µ-law / a-law，装在 .aiff / .wav / .caf 里。
#     所以 mp3 直接用不了（这份脚本特意选 **WAV + 线性 PCM**：最保守、不会解码失败）；
#   * **最长 30 秒**，而且**不会循环** —— 超时的那部分会被系统直接砍掉。
#
# 所以：把 `assets/audio/calling.mp3`（4.44 秒，应用内是 `LoopMode.one` 循环放的）
# 接 6 遍 ≈ 26.6 秒 —— 既在 30 秒内、又留一点余量，听起来就是「一直在响」。
#
# 跑法（开发机上，需要有 ffmpeg；产出**要进仓库**，CI 不需要 ffmpeg）：
#   bash tool/audio/make-ios-ringtone.sh
#
# 自带验收：格式、声道、采样率、时长、体积，任何一条不对就当场失败 ——
# 这个文件一旦是坏的，表现是「来电又只剩一声叮」，而那是在真机上才会发现的。
set -euo pipefail

cd "$(dirname "$0")/../.."

SOURCE="assets/audio/calling.mp3"
TARGET="ios/Runner/call_ring.wav"

# 4.44 秒 × 6 ≈ 26.6 秒（上限 30 秒，留 3 秒余量给不同版本的舍入）
LOOPS=6
MAX_SECONDS=30

for tool in ffmpeg ffprobe; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "缺少 $tool —— 这个脚本只在开发机上跑一次（产出已经进仓库），装上 ffmpeg 再试" >&2
    exit 1
  fi
done

if [ ! -f "$SOURCE" ]; then
  echo "找不到 $SOURCE" >&2
  exit 1
fi

echo "来源：$SOURCE（$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$SOURCE") 秒）"
echo "接 ${LOOPS} 遍 → $TARGET"

ffmpeg -v error -y \
  -stream_loop $((LOOPS - 1)) -i "$SOURCE" \
  -ac 1 -ar 22050 -c:a pcm_s16le \
  -t "$MAX_SECONDS" \
  "$TARGET"

# ── 验收（不看输出等于没验）────────────────────────────────────────────────
# 挨个问、不拼一条 `read`：ffprobe 的字段顺序是它自己定的（sample_rate 排在
# channels 前面），拼一行读回来极易错位 —— 错位的验收比没有验收更坑。
probe() {
  ffprobe -v error -select_streams a:0 -show_entries "$1" \
    -of default=noprint_wrappers=1:nokey=1 "$TARGET"
}
CODEC=$(probe stream=codec_name)
RATE=$(probe stream=sample_rate)
CHANNELS=$(probe stream=channels)
DURATION=$(probe format=duration)

bytes=$(wc -c < "$TARGET")

fail=0
check() {
  local what="$1" ok="$2" detail="$3"
  if [ "$ok" = "1" ]; then
    echo "  ✓ $what：$detail"
  else
    echo "  ✗ $what：$detail" >&2
    fail=1
  fi
}

echo "验收 $TARGET："
check "格式是线性 PCM（iOS 只认这几种）" \
  "$([ "$CODEC" = "pcm_s16le" ] && echo 1 || echo 0)" "$CODEC"
check "单声道" "$([ "$CHANNELS" = "1" ] && echo 1 || echo 0)" "${CHANNELS} 声道"
check "采样率 22050" "$([ "$RATE" = "22050" ] && echo 1 || echo 0)" "${RATE} Hz"
check "时长 ≤ ${MAX_SECONDS} 秒（超了会被系统砍）" \
  "$(awk -v d="$DURATION" -v m="$MAX_SECONDS" 'BEGIN{print (d>0 && d<=m) ? 1 : 0}')" \
  "${DURATION} 秒"
check "时长 ≥ 20 秒（太短就又成一声叮了）" \
  "$(awk -v d="$DURATION" 'BEGIN{print (d>=20) ? 1 : 0}')" "${DURATION} 秒"
check "体积合理（<2MB）" \
  "$([ "$bytes" -lt 2097152 ] && echo 1 || echo 0)" "$(($bytes / 1024)) KB"

if [ "$fail" -ne 0 ]; then
  echo "验收没过：这个文件别提交" >&2
  exit 1
fi

echo "好了。别忘了它还要进 Xcode 的 Resources 那一相（project.pbxproj），"
echo "否则它不会被打进 .app —— 那件事由 test/core/ios_runner_test.dart 守着。"
