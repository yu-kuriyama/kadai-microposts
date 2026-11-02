@echo off
rem Windows 用：Docker を使わずに起動する
cd /d %~dp0
where ffmpeg >nul 2>nul || echo ※ ffmpeg が見つかりません（winget install ffmpeg）
where deno >nul 2>nul || echo ※ deno が見つかりません。YouTube で必要です（winget install DenoLand.Deno）
if not exist .venv python -m venv .venv
call .venv\Scripts\activate.bat
pip install -q -U -r requirements.txt
echo.
echo iPhone の Safari で http://（このPCのIPアドレス）:8000 を開いてください
echo IPアドレスは ipconfig の「IPv4 アドレス」で確認できます
echo.
uvicorn app.main:app --host 0.0.0.0 --port 8000
