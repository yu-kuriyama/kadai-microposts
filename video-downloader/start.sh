#!/bin/sh
# Mac / Linux 用：Docker を使わずに起動する
cd "$(dirname "$0")"
command -v ffmpeg >/dev/null || echo "※ ffmpeg が見つかりません（Mac なら: brew install ffmpeg）"
command -v deno >/dev/null || echo "※ deno が見つかりません。YouTube で必要です（Mac なら: brew install deno）"
[ -d .venv ] || python3 -m venv .venv
. .venv/bin/activate
pip install -q -U -r requirements.txt
IP=$( (ipconfig getifaddr en0 || hostname -I | awk '{print $1}') 2>/dev/null )
echo ""
echo "iPhone の Safari で開く:  http://${IP:-このPCのIP}:8000"
echo ""
exec uvicorn app.main:app --host 0.0.0.0 --port 8000
