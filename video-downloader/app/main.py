"""動画ダウンローダー（サーバー側）

yt-dlp で動画を取得し、iPhone の Safari から操作できる API と画面を提供する。
"""
from __future__ import annotations

import json
import os
import re
import secrets
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import quote, urljoin

import httpx
import yt_dlp
from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

BASE_DIR = Path(__file__).resolve().parent
DOWNLOAD_DIR = Path(os.environ.get("DOWNLOAD_DIR", BASE_DIR.parent / "downloads")).resolve()
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
JOBS_FILE = DOWNLOAD_DIR / "jobs.json"
APP_PASSWORD = os.environ.get("APP_PASSWORD", "")
MAX_PARALLEL = int(os.environ.get("MAX_PARALLEL", "2"))
COOKIES_FILE = os.environ.get("COOKIES_FILE", "")

# 画質モード → yt-dlp のフォーマット指定
FORMATS = {
    # iPhone の写真アプリでそのまま再生できる H.264 + AAC の mp4 を優先
    "iphone": "bv*[vcodec^=avc1]+ba[acodec^=mp4a]/b[vcodec^=avc1]/bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b",
    "best": "bv*+ba/b",
    "audio": "ba[ext=m4a]/ba/b",
}

MEDIA_URL_RE = re.compile(
    r"""(?:https?:)?//[^\s"'<>\\]+?\.(?:mp4|m3u8|webm|mov|m4v|mpd)(?:\?[^\s"'<>\\]*)?""",
    re.IGNORECASE,
)
UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
)

app = FastAPI(title="動画ダウンローダー")
executor = ThreadPoolExecutor(max_workers=MAX_PARALLEL)
lock = threading.Lock()
jobs: dict[str, dict] = {}


# ---------------------------------------------------------------- 保存・読込
def save_jobs() -> None:
    with lock:
        data = list(jobs.values())
    tmp = JOBS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    tmp.replace(JOBS_FILE)


def load_jobs() -> None:
    if not JOBS_FILE.exists():
        return
    try:
        for j in json.loads(JOBS_FILE.read_text(encoding="utf-8")):
            if j.get("status") in ("queued", "downloading", "processing"):
                j["status"] = "error"
                j["error"] = "サーバー再起動で中断されました。もう一度お試しください。"
            jobs[j["id"]] = j
    except Exception:
        pass


load_jobs()


def update(job_id: str, **kw) -> None:
    with lock:
        if job_id in jobs:
            jobs[job_id].update(kw)


# ---------------------------------------------------------------- ダウンロード処理
def ydl_opts(job_id: str, mode: str) -> dict:
    job_dir = DOWNLOAD_DIR / job_id
    last = {"t": 0.0}

    def hook(d: dict) -> None:
        if job_id not in jobs:  # 削除済み → 中止
            raise yt_dlp.utils.DownloadCancelled()
        if d["status"] == "downloading":
            now = time.time()
            if now - last["t"] < 0.5:
                return
            last["t"] = now
            total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            done = d.get("downloaded_bytes") or 0
            update(
                job_id,
                status="downloading",
                progress=round(done / total * 100, 1) if total else None,
                speed=d.get("speed"),
                eta=d.get("eta"),
                downloaded=done,
                total=total or None,
            )
        elif d["status"] == "finished":
            update(job_id, status="processing", progress=100)

    opts = {
        "format": FORMATS.get(mode, FORMATS["iphone"]),
        "outtmpl": str(job_dir / "%(title).150B [%(id)s].%(ext)s"),
        "noplaylist": True,
        "restrictfilenames": False,
        "windowsfilenames": True,
        "progress_hooks": [hook],
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "retries": 5,
        "fragment_retries": 10,
        "concurrent_fragment_downloads": 4,
        "socket_timeout": 30,
        "http_headers": {"User-Agent": UA},
    }
    if mode == "audio":
        opts["postprocessors"] = [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a"}]
    else:
        opts["merge_output_format"] = "mp4"
        # 単体ファイル（webm など）でも最終的に mp4 にまとめる
        opts["postprocessors"] = [{"key": "FFmpegVideoRemuxer", "preferedformat": "mp4"}]
    if COOKIES_FILE and Path(COOKIES_FILE).exists():
        opts["cookiefile"] = COOKIES_FILE
    return opts


def find_media_urls(page_url: str) -> list[str]:
    """yt-dlp が失敗したとき用：ページの HTML から動画ファイルの URL を探す"""
    try:
        r = httpx.get(page_url, headers={"User-Agent": UA}, follow_redirects=True, timeout=20)
        html = r.text.replace("\\/", "/")
    except Exception:
        return []
    found: list[str] = []
    for m in MEDIA_URL_RE.findall(html):
        u = urljoin(str(r.url), "https:" + m if m.startswith("//") else m)
        if u not in found:
            found.append(u)
    # m3u8 / mp4 を優先
    found.sort(key=lambda u: (0 if ".m3u8" in u.lower() else 1 if ".mp4" in u.lower() else 2))
    return found[:5]


def run_job(job_id: str) -> None:
    job = jobs.get(job_id)
    if not job:
        return
    url, mode = job["url"], job["mode"]
    job_dir = DOWNLOAD_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    update(job_id, status="downloading", progress=0)

    def attempt(target: str, referer: str | None = None) -> dict:
        opts = ydl_opts(job_id, mode)
        if referer:
            opts["http_headers"] = {**opts["http_headers"], "Referer": referer}
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(target, download=True)
            if info.get("_type") == "playlist" and info.get("entries"):
                info = next(e for e in info["entries"] if e)
            return info

    error = None
    info = None
    try:
        info = attempt(url)
    except yt_dlp.utils.DownloadCancelled:
        return
    except Exception as e:  # noqa: BLE001
        error = e
        for media in find_media_urls(url):
            try:
                info = attempt(media, referer=url)
                error = None
                break
            except yt_dlp.utils.DownloadCancelled:
                return
            except Exception:  # noqa: BLE001
                continue

    if job_id not in jobs:
        return
    files = [p for p in job_dir.iterdir() if p.is_file() and not p.name.endswith((".part", ".ytdl"))]
    if info is None or not files:
        msg = clean_error(error) if error else "動画が見つかりませんでした。"
        update(job_id, status="error", error=msg)
    else:
        f = max(files, key=lambda p: p.stat().st_size)
        update(
            job_id,
            status="done",
            progress=100,
            title=info.get("title") or f.stem,
            thumbnail=info.get("thumbnail"),
            filename=f.name,
            size=f.stat().st_size,
            finished_at=time.time(),
        )
    save_jobs()


def clean_error(e: Exception) -> str:
    msg = re.sub(r"\x1b\[[0-9;]*m", "", str(e)).replace("ERROR: ", "")
    msg = re.split(r";\s*please report this issue", msg)[0]
    msg = re.split(r"\s*\(caused by", msg)[0]
    if "Unable to connect" in msg or "Tunnel connection" in msg or "timed out" in msg:
        return "サイトに接続できませんでした（サーバーのネット接続を確認してください）。"
    if "HTTP Error 404" in msg:
        return "ページが見つかりません（404）。URLを確認してください。"
    if "HTTP Error 403" in msg:
        return "サイトにアクセスを拒否されました（403）。少し時間をおくか、ログイン用クッキーを設定してください。"
    if "DRM" in msg:
        return "この動画はDRM（コピー防止）で保護されているためダウンロードできません。"
    if "Sign in" in msg or "login" in msg.lower() or "cookies" in msg.lower():
        return "このサイトはログインが必要です（README の「ログインが必要なサイト」を参照）。\n" + msg[:300]
    if "Unsupported URL" in msg:
        return "このページから動画を見つけられませんでした。動画の再生ページのURLか確認してください。"
    return msg[:500]


# ---------------------------------------------------------------- 認証
def check_auth(
    x_app_password: str | None = Header(default=None),
    key: str | None = Query(default=None),
) -> None:
    if not APP_PASSWORD:
        return
    given = x_app_password or key or ""
    if not secrets.compare_digest(given.encode(), APP_PASSWORD.encode()):
        raise HTTPException(401, "パスワードが違います")


# ---------------------------------------------------------------- API
class JobRequest(BaseModel):
    urls: list[str]
    mode: str = "iphone"


URL_IN_TEXT = re.compile(r"https?://[^\s<>\"'「」]+")


@app.get("/api/ping", dependencies=[Depends(check_auth)])
def ping():
    return {"ok": True, "version": yt_dlp.version.__version__}


@app.post("/api/jobs", dependencies=[Depends(check_auth)])
def create_jobs(req: JobRequest):
    # 共有テキストなどに混ざった URL もすべて拾う
    urls: list[str] = []
    for line in req.urls:
        for u in URL_IN_TEXT.findall(line):
            u = u.rstrip(".,)」』】")
            if u not in urls:
                urls.append(u)
    if not urls:
        raise HTTPException(400, "URLが見つかりません")
    mode = req.mode if req.mode in FORMATS else "iphone"
    created = []
    for u in urls[:50]:
        jid = uuid.uuid4().hex[:12]
        job = {
            "id": jid,
            "url": u,
            "mode": mode,
            "status": "queued",
            "progress": 0,
            "title": None,
            "created_at": time.time(),
        }
        with lock:
            jobs[jid] = job
        executor.submit(run_job, jid)
        created.append(job)
    save_jobs()
    return created


@app.get("/api/jobs", dependencies=[Depends(check_auth)])
def list_jobs():
    with lock:
        return sorted(jobs.values(), key=lambda j: j["created_at"], reverse=True)


@app.get("/api/jobs/{job_id}/file", dependencies=[Depends(check_auth)])
def get_file(job_id: str, inline: bool = False):
    job = jobs.get(job_id)
    if not job or job.get("status") != "done":
        raise HTTPException(404, "ファイルがありません")
    path = (DOWNLOAD_DIR / job_id / job["filename"]).resolve()
    if DOWNLOAD_DIR not in path.parents or not path.exists():
        raise HTTPException(404, "ファイルがありません")
    disp = "inline" if inline else "attachment"
    return FileResponse(
        path,
        headers={"Content-Disposition": f"{disp}; filename*=UTF-8''{quote(path.name)}"},
    )


@app.delete("/api/jobs/{job_id}", dependencies=[Depends(check_auth)])
def delete_job(job_id: str):
    with lock:
        job = jobs.pop(job_id, None)
    if not job:
        raise HTTPException(404)
    job_dir = DOWNLOAD_DIR / job_id
    if job_dir.exists():
        for p in job_dir.iterdir():
            try:
                p.unlink()
            except OSError:
                pass
        try:
            job_dir.rmdir()
        except OSError:
            pass
    save_jobs()
    return {"ok": True}


@app.post("/api/jobs/{job_id}/retry", dependencies=[Depends(check_auth)])
def retry_job(job_id: str):
    job = jobs.get(job_id)
    if not job:
        raise HTTPException(404)
    update(job_id, status="queued", progress=0, error=None)
    executor.submit(run_job, job_id)
    return jobs[job_id]


app.mount("/", StaticFiles(directory=BASE_DIR / "static", html=True), name="static")
