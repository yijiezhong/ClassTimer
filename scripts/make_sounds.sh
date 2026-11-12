#!/usr/bin/env bash
#
# 生成课堂计时器的经典提示音（木鱼滴答 + 结束铃与台词）。
#
# 产出（Resources/）：
#   woodblock.wav    单下木鱼——最后 10 秒每秒敲一下
#   rest-chime.wav   佛铃 → 台词「休息，休息一下吧」——计时结束提醒
#
# 成品结构（rest-chime.wav）：佛铃完整衰减（约 1.9s）→ 台词。
# 木鱼不放进成品里——最后 10 秒由 app 逐秒播放 woodblock.wav；
# 剩余 1 秒时开始播 rest-chime.wav，所以铃在最后一秒起响，
# 铃尾音自然收掉之后台词才进来，两者不重叠。
#
# 重新生成：
#   ./scripts/make_sounds.sh <木鱼素材.wav> <台词素材.wav>
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

WOOD_SRC="${1:-/tmp/wood-source.wav}"   # 含木鱼/佛铃的素材
PHRASE_SRC="${2:-/tmp/phrase-source.wav}"  # 含台词「休息，休息一下吧」的素材

mkdir -p "$OUT"

# 1) 只取佛铃（思考桥段里 552.55s 那一声；相对 549.15s 是 3.45s）
ffmpeg -y -loglevel error -ss 549.15 -t 5.15 -i "$WOOD_SRC" \
  -af "highpass=f=45,afade=t=in:st=0:d=0.01,afade=t=out:st=4.95:d=0.20" \
  "$WORK/wood_ring.wav"
# 铃：低通 4000Hz + 高频搁架 -4dB，削掉刺耳泛音但保留金属感
ffmpeg -y -loglevel error -ss 3.35 -t 1.95 -i "$WORK/wood_ring.wav" \
  -af "highpass=f=80,lowpass=f=4000,highshelf=g=-4:f=2000,volume=0.82,afade=t=in:st=0:d=0.01,afade=t=out:st=1.85:d=0.10" \
  "$WORK/bell.wav"

# 2) 单下木鱼（滴答用）：低通 3000Hz 去尖锐噪声，高频搁架再压 3dB
ffmpeg -y -loglevel error -ss 549.20 -t 0.34 -i "$WOOD_SRC" \
  -af "highpass=f=45,lowpass=f=3000,highshelf=g=-3:f=1200,volume=0.88,afade=t=out:st=0.27:d=0.07" \
  "$OUT/woodblock.wav"

# 3) 童声台词「休息！休息一会儿！」
# 台词：低通 5500Hz 减弱齿音。
# 起点必须是 7.70——7.35~7.78 是上一个字「急」的残尾，会把「休息！」的开头糊掉。
ffmpeg -y -loglevel error -ss 7.70 -t 2.15 -i "$PHRASE_SRC" \
  -af "highpass=f=80,lowpass=f=5500,highshelf=g=-2:f=2500,volume=1.10,afade=t=in:st=0:d=0.01,afade=t=out:st=2.10:d=0.05" \
  "$WORK/phrase.wav"

# 4) 拼接：佛铃 0.00s，台词 1.95s（铃尾音自然收掉后再进台词，不重叠）
ffmpeg -y -loglevel error -i "$WORK/bell.wav" -i "$WORK/phrase.wav" \
  -filter_complex "\
[0:a]aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=mono,volume=1.0[a0];\
[1:a]aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=mono,volume=1.25,adelay=1950[a1];\
[a0][a1]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.92,afade=t=out:st=4.40:d=0.05" \
  "$OUT/rest-chime.wav"

echo "已生成："
afinfo "$OUT/woodblock.wav" | grep "estimated duration" | sed 's/^/  woodblock  /'
afinfo "$OUT/rest-chime.wav" | grep "estimated duration" | sed 's/^/  rest-chime /'
