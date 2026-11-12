#!/usr/bin/env bash
#
# 合成「轻柔」提示音方案（不依赖任何外部素材，纯 ffmpeg lavfi 生成）。
#
# 产出（Resources/）：
#   soft-tick.wav    一下柔和的滴答（最后 10 秒每秒一次）
#   soft-chime.wav   一段柔和的钟声（计时结束提醒，无台词）
#
# 设计取向：比经典提示音更轻、更短、不吓人——适合小班、安静教室或投屏音量偏大的场合。
#   soft-tick ：880Hz + 440Hz 泛音，30ms 指数衰减，低通 2500Hz
#   soft-chime：C5-E5-G5（523.25/659.25/783.99Hz）叠加，2 秒自然衰减，低通 5000Hz
#
# 重新生成：
#   ./scripts/make_soft_sounds.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources"
mkdir -p "$OUT"

# 1) 轻柔滴答：两个正弦叠加 + 指数衰减，0.18 秒
ffmpeg -y -loglevel error -f lavfi \
  -i "aevalsrc=0.45*sin(2*PI*880*t)*exp(-28*t)+0.18*sin(2*PI*440*t)*exp(-22*t):s=44100:d=0.18" \
  -af "lowpass=f=2500,afade=t=out:st=0.12:d=0.06,volume=0.9" \
  -ac 1 -c:a pcm_s16le "$OUT/soft-tick.wav"

# 2) 轻柔钟声：C5 大三和弦叠加，2.2 秒指数衰减
ffmpeg -y -loglevel error -f lavfi \
  -i "aevalsrc=0.20*sin(2*PI*523.25*t)*exp(-2.6*t)+0.16*sin(2*PI*659.25*t)*exp(-2.2*t)+0.13*sin(2*PI*783.99*t)*exp(-1.8*t)+0.06*sin(2*PI*1046.5*t)*exp(-3.5*t):s=44100:d=2.4" \
  -af "lowpass=f=5000,afade=t=in:st=0:d=0.01,afade=t=out:st=2.0:d=0.4,volume=0.8,alimiter=limit=0.92" \
  -ac 1 -c:a pcm_s16le "$OUT/soft-chime.wav"

echo "已生成："
afinfo "$OUT/soft-tick.wav" | grep "estimated duration" | sed 's/^/  soft-tick  /'
afinfo "$OUT/soft-chime.wav" | grep "estimated duration" | sed 's/^/  soft-chime /'
