FROM python:3.12-slim
# ffmpeg: 映像+音声の結合・変換用 / deno: YouTube の解析に必要な JavaScript 実行環境
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl unzip ca-certificates \
 && curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh \
 && apt-get purge -y unzip && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
ENV DOWNLOAD_DIR=/data
VOLUME /data
EXPOSE 8000
# 起動のたびに yt-dlp を最新にする（サイト側の仕様変更に追従するため）
CMD pip install -q -U "yt-dlp[default]" ; uvicorn app.main:app --host 0.0.0.0 --port 8000
