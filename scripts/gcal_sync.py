#!/usr/bin/env python3
"""
Google Calendar, Google Tasks & Local Daily Tasks helper for Omarchy Clock (hihry.clock).
Uses 100% Python 3 standard library (zero external pip dependencies).
Works standalone or alongside the companion hihry.tasks plugin.
"""

import argparse
import base64
import datetime
import hashlib
import html
import http.server
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HOME = Path.home()
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "omarchy" / "google-calendar"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local" / "state")) / "omarchy"

CREDENTIALS_PATH = CONFIG_DIR / "credentials.json"
CONFIG_PATH = CONFIG_DIR / "config.json"
README_PATH = CONFIG_DIR / "README.md"
TOKEN_PATH = STATE_DIR / "gcal-token.json"
CACHE_PATH = STATE_DIR / "gcal-events.json"
TASKS_PATH = STATE_DIR / "daily-tasks.json"

SCOPES = [
    "https://www.googleapis.com/auth/calendar.events",
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/tasks.readonly",
]

DEFAULT_GCAL_PALETTE = {
    "1": {"id": "1", "name": "Lavender", "hex": "#7986cb"},
    "2": {"id": "2", "name": "Sage", "hex": "#33b679"},
    "3": {"id": "3", "name": "Grape", "hex": "#8e24aa"},
    "4": {"id": "4", "name": "Flamingo", "hex": "#e67c73"},
    "5": {"id": "5", "name": "Banana", "hex": "#f6bf26"},
    "6": {"id": "6", "name": "Tangerine", "hex": "#f4511e"},
    "7": {"id": "7", "name": "Peacock", "hex": "#039be5"},
    "8": {"id": "8", "name": "Graphite", "hex": "#616161"},
    "9": {"id": "9", "name": "Blueberry", "hex": "#3f51b5"},
    "10": {"id": "10", "name": "Basil", "hex": "#0b8043"},
    "11": {"id": "11", "name": "Tomato", "hex": "#d50000"},
}

SETUP_GUIDE_MD = """# Google Calendar Setup for Omarchy (`hihry.clock`)

To connect your Google Calendar and Google Tasks to the Omarchy Calendar popup:

## Step 1: Create OAuth 2.0 Desktop Credentials in Google Cloud

1. Open the [Google Cloud Console — APIs & Services](https://console.cloud.google.com/apis/dashboard).
2. Create or select a project, then enable:
   - **Google Calendar API** ([enable link](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com))
   - *(Optional)* **Google Tasks API** ([enable link](https://console.cloud.google.com/apis/library/tasks.googleapis.com))
3. In **OAuth consent screen**, add your Google email under **Test users** (if in External testing mode).
4. Go to **Credentials** → **+ Create Credentials** → **OAuth client ID**:
   - Application type: **Desktop app**
   - Name: `Omarchy Calendar`
5. Click **Download JSON** and save the file to:
   ```
   ~/.config/omarchy/google-calendar/credentials.json
   ```

## Step 2: Authorize in Browser

Once `credentials.json` is saved, open the Omarchy Calendar popup (click the clock in the top bar) and click **Connect GCal**.
"""


def ensure_dirs():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not README_PATH.exists():
        try:
            README_PATH.write_text(SETUP_GUIDE_MD, encoding="utf-8")
        except Exception:
            pass


def atomic_write_json(path: Path, data: dict, mode: int = 0o644):
    ensure_dirs()
    tmp_path = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp_path, mode)
    os.replace(tmp_path, path)


def read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


# ---- Local Daily Tasks Management (Shared with hihry.tasks) -----------------

def today_date_key() -> str:
    return datetime.date.today().isoformat()


def tomorrow_date_key() -> str:
    return (datetime.date.today() + datetime.timedelta(days=1)).isoformat()


def day_role_for_date(date_key: str, is_done: bool) -> str:
    today_k = today_date_key()
    tomorrow_k = tomorrow_date_key()
    if date_key == today_k:
        return "today"
    if date_key == tomorrow_k:
        return "tomorrow"
    if date_key > tomorrow_k:
        return "scheduled"
    return "history" if is_done else "today"


def load_tasks_state() -> tuple[str, list[dict]]:
    raw = read_json(TASKS_PATH)
    active_date = str(raw.get("activeDate") or today_date_key())
    tasks = raw.get("tasks")
    if not isinstance(tasks, list):
        tasks = []
    return active_date, [t for t in tasks if isinstance(t, dict)]


def save_tasks_state(active_date: str, tasks: list[dict]):
    atomic_write_json(
        TASKS_PATH,
        {
            "version": 1,
            "activeDate": active_date or today_date_key(),
            "tasks": tasks,
        },
    )


def local_add_task(date_key: str, text: str, priority: str = "normal", color: str = "") -> dict:
    clean_text = (text or "").strip()
    if not clean_text:
        return {"ok": False, "error": "Task text is empty"}

    today_k = today_date_key()
    clean_date = date_key.strip() if re.match(r"^\d{4}-\d{2}-\d{2}$", str(date_key or "").strip()) else today_k
    if clean_date < today_k:
        clean_date = today_k

    clean_pri = priority if priority in ("high", "normal", "low") else "normal"
    clean_color = color.strip() if re.match(r"^#[0-9A-Fa-f]{6}$", str(color or "").strip()) else ""

    active_date, tasks = load_tasks_state()
    now_ms = int(time.time() * 1000)
    new_task = {
        "id": f"t_{now_ms}_{len(tasks) + 1}",
        "text": clean_text,
        "day": day_role_for_date(clean_date, False),
        "date": clean_date,
        "priority": clean_pri,
        "color": clean_color,
        "done": False,
        "createdAt": now_ms,
        "completedAt": 0,
        "carriedOver": False,
    }
    tasks.append(new_task)
    save_tasks_state(active_date, tasks)
    return {"ok": True, "task": new_task}


def local_toggle_task(task_id: str) -> dict:
    active_date, tasks = load_tasks_state()
    today_k = today_date_key()
    now_ms = int(time.time() * 1000)
    updated = False
    for t in tasks:
        if str(t.get("id")) == str(task_id):
            next_done = not bool(t.get("done"))
            item_date = str(t.get("date") or today_k)
            t["done"] = next_done
            t["day"] = day_role_for_date(item_date, next_done)
            t["date"] = item_date
            t["completedAt"] = now_ms if next_done else 0
            updated = True
            break
    if updated:
        save_tasks_state(active_date, tasks)
    return {"ok": updated}


def local_cycle_priority(task_id: str) -> dict:
    order = ["normal", "high", "low"]
    active_date, tasks = load_tasks_state()
    updated = False
    for t in tasks:
        if str(t.get("id")) == str(task_id):
            cur = str(t.get("priority") or "normal")
            idx = order.index(cur) if cur in order else 0
            t["priority"] = order[(idx + 1) % len(order)]
            updated = True
            break
    if updated:
        save_tasks_state(active_date, tasks)
    return {"ok": updated}


def local_delete_task(task_id: str) -> dict:
    active_date, tasks = load_tasks_state()
    next_tasks = [t for t in tasks if str(t.get("id")) != str(task_id)]
    if len(next_tasks) != len(tasks):
        save_tasks_state(active_date, next_tasks)
    return {"ok": True}


# ---- Google Calendar & Google Tasks OAuth2 ----------------------------------

def load_client_credentials() -> dict | None:
    raw = read_json(CREDENTIALS_PATH)
    if not raw:
        return None
    block = raw.get("installed") or raw.get("web") or raw
    client_id = block.get("client_id")
    client_secret = block.get("client_secret", "")
    auth_uri = block.get("auth_uri", "https://accounts.google.com/o/oauth2/v2/auth")
    token_uri = block.get("token_uri", "https://oauth2.googleapis.com/token")
    if not client_id:
        return None
    return {
        "client_id": str(client_id).strip(),
        "client_secret": str(client_secret).strip(),
        "auth_uri": str(auth_uri).strip(),
        "token_uri": str(token_uri).strip(),
    }


def load_user_config() -> dict:
    return read_json(CONFIG_PATH)


def http_json(url: str, method: str = "GET", headers: dict | None = None, body: bytes | None = None, timeout: int = 15) -> dict:
    req = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
        return json.loads(raw) if raw.strip() else {}


def get_valid_access_token() -> str:
    creds = load_client_credentials()
    if not creds:
        raise RuntimeError(f"Missing OAuth credentials at {CREDENTIALS_PATH}")
    token_data = read_json(TOKEN_PATH)
    if not token_data:
        raise RuntimeError("Not authenticated with Google Calendar yet. Click 'Connect GCal' to sign in.")

    now = time.time()
    access_token = token_data.get("access_token", "")
    expires_at = float(token_data.get("expires_at", 0))
    refresh_token = token_data.get("refresh_token", "")

    if access_token and expires_at > now + 60:
        return access_token

    if not refresh_token:
        raise RuntimeError("OAuth token expired and no refresh_token available. Please re-authenticate.")

    form = {
        "client_id": creds["client_id"],
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    }
    if creds["client_secret"]:
        form["client_secret"] = creds["client_secret"]

    encoded = urllib.parse.urlencode(form).encode("utf-8")
    try:
        resp = http_json(
            creds["token_uri"],
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            body=encoded,
        )
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Token refresh failed ({e.code}): {err_body}") from e

    new_access = resp.get("access_token", "")
    if not new_access:
        raise RuntimeError("Token refresh response did not contain access_token")

    token_data["access_token"] = new_access
    token_data["expires_at"] = now + float(resp.get("expires_in", 3600))
    if resp.get("refresh_token"):
        token_data["refresh_token"] = resp["refresh_token"]
    atomic_write_json(TOKEN_PATH, token_data, mode=0o600)
    return new_access


def open_url(url: str):
    if shutil.which("xdg-open"):
        subprocess.Popen(
            ["xdg-open", url],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return
    import webbrowser
    webbrowser.open(url)


def run_oauth_flow() -> dict:
    ensure_dirs()
    creds = load_client_credentials()
    if not creds:
        msg = (
            f"Missing {CREDENTIALS_PATH}. Place your Google Cloud Desktop OAuth2 "
            "credentials.json file there and click Connect GCal again."
        )
        update_cache_status(authenticated=False, last_error=msg)
        if README_PATH.exists():
            open_url(str(README_PATH))
        return {"ok": False, "error": msg, "credentialsPath": str(CREDENTIALS_PATH)}

    code_verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode("ascii")
    digest = hashlib.sha256(code_verifier.encode("ascii")).digest()
    code_challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    state_token = secrets.token_urlsafe(16)

    auth_result = {"code": None, "error": None, "state": None}

    class OAuthCallbackHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            params = urllib.parse.parse_qs(parsed.query)
            auth_result["code"] = (params.get("code") or [None])[0]
            auth_result["error"] = (params.get("error") or [None])[0]
            auth_result["state"] = (params.get("state") or [None])[0]

            ok = bool(auth_result["code"]) and auth_result["state"] == state_token
            title = "Google Calendar Connected!" if ok else "Google Calendar Authorization Failed"
            subtitle = (
                "Omarchy Calendar is now linked. You can close this browser tab."
                if ok
                else f"Error: {html.escape(str(auth_result['error'] or 'Invalid state or missing code'))}"
            )
            accent = "#33b679" if ok else "#e06c75"
            body = f"""<!doctype html>
<html>
<head><meta charset="utf-8"><title>{title}</title></head>
<body style="background:#101315;color:#cacccc;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
  <div style="border:1px solid {accent};border-radius:10px;padding:32px 40px;max-width:460px;text-align:center;background:#161a1d">
    <h2 style="color:{accent};margin-top:0">{title}</h2>
    <p style="line-height:1.5;color:#a0a8b0">{subtitle}</p>
  </div>
</body>
</html>""".encode("utf-8")
            self.send_response(200 if ok else 400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = http.server.HTTPServer(("127.0.0.1", 0), OAuthCallbackHandler)
    server.timeout = 180
    port = server.server_port
    redirect_uri = f"http://127.0.0.1:{port}"

    query = urllib.parse.urlencode({
        "client_id": creds["client_id"],
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": " ".join(SCOPES),
        "access_type": "offline",
        "prompt": "consent",
        "state": state_token,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
    })
    auth_url = f"{creds['auth_uri']}?{query}"
    open_url(auth_url)

    deadline = time.time() + 180
    while time.time() < deadline and auth_result["code"] is None and auth_result["error"] is None:
        server.handle_request()
    server.server_close()

    if auth_result["error"]:
        msg = f"OAuth error: {auth_result['error']}"
        update_cache_status(authenticated=False, last_error=msg)
        return {"ok": False, "error": msg}

    if not auth_result["code"] or auth_result["state"] != state_token:
        msg = "Timed out waiting for Google authorization in browser."
        update_cache_status(authenticated=False, last_error=msg)
        return {"ok": False, "error": msg}

    token_form = {
        "client_id": creds["client_id"],
        "code": auth_result["code"],
        "code_verifier": code_verifier,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    }
    if creds["client_secret"]:
        token_form["client_secret"] = creds["client_secret"]

    try:
        token_resp = http_json(
            creds["token_uri"],
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            body=urllib.parse.urlencode(token_form).encode("utf-8"),
        )
    except urllib.error.HTTPError as e:
        err_text = e.read().decode("utf-8", errors="replace")
        msg = f"Failed to exchange auth code ({e.code}): {err_text}"
        update_cache_status(authenticated=False, last_error=msg)
        return {"ok": False, "error": msg}

    now = time.time()
    saved_token = {
        "access_token": token_resp.get("access_token", ""),
        "refresh_token": token_resp.get("refresh_token", ""),
        "expires_at": now + float(token_resp.get("expires_in", 3600)),
        "scope": token_resp.get("scope", " ".join(SCOPES)),
        "token_type": token_resp.get("token_type", "Bearer"),
        "created_at": int(now * 1000),
    }
    atomic_write_json(TOKEN_PATH, saved_token, mode=0o600)
    return sync_events()


def parse_iso_datetime_to_local(iso_str: str) -> datetime.datetime | None:
    if not iso_str:
        return None
    cleaned = iso_str.strip()
    if cleaned.endswith("Z"):
        cleaned = cleaned[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(cleaned)
        if dt.tzinfo is not None:
            dt = dt.astimezone()
        return dt
    except Exception:
        return None


def compute_sync_window(year: int | None, month: int | None) -> tuple[datetime.datetime, datetime.datetime]:
    now = datetime.datetime.now().astimezone()
    y = year if year and 1970 <= year <= 2100 else now.year
    m = month if month and 1 <= month <= 12 else now.month

    start_month = m - 1
    start_year = y
    if start_month < 1:
        start_month += 12
        start_year -= 1

    end_month = m + 2
    end_year = y
    while end_month > 12:
        end_month -= 12
        end_year += 1

    tz = now.tzinfo
    time_min = datetime.datetime(start_year, start_month, 1, 0, 0, 0, tzinfo=tz)
    time_max = datetime.datetime(end_year, end_month, 28, 23, 59, 59, tzinfo=tz)
    return time_min, time_max


def update_cache_status(authenticated: bool | None = None, last_error: str = "") -> dict:
    existing = read_json(CACHE_PATH)
    creds = load_client_credentials()
    token = read_json(TOKEN_PATH)
    is_auth = authenticated if authenticated is not None else bool(creds and (token.get("refresh_token") or token.get("access_token")))

    payload = {
        "version": 1,
        "hasCredentials": bool(creds),
        "credentialsPath": str(CREDENTIALS_PATH),
        "authenticated": is_auth,
        "syncedAt": existing.get("syncedAt", 0),
        "lastError": last_error,
        "palette": existing.get("palette") or DEFAULT_GCAL_PALETTE,
        "calendars": existing.get("calendars") or [],
        "eventsByDate": existing.get("eventsByDate") or {},
    }
    atomic_write_json(CACHE_PATH, payload)
    return payload


def parse_ics_events(ics_text: str, cal_name: str, cal_color: str, events_by_date: dict):
    unfolded = re.sub(r"\r?\n[ \t]", "", ics_text)
    blocks = re.findall(r"BEGIN:VEVENT(.*?)END:VEVENT", unfolded, flags=re.DOTALL)
    for idx, block in enumerate(blocks):
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        props = {}
        for line in lines:
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            base_k = k.split(";", 1)[0].upper()
            props[base_k] = v.strip()
        summary = props.get("SUMMARY", "Busy").replace(r"\,", ",").replace(r"\;", ";")
        uid = props.get("UID", f"ics_{idx}")
        dtstart = props.get("DTSTART", "")
        if len(dtstart) >= 8 and dtstart[:8].isdigit():
            date_key = f"{dtstart[0:4]}-{dtstart[4:6]}-{dtstart[6:8]}"
            start_time = ""
            all_day = True
            if "T" in dtstart and len(dtstart) >= 13:
                all_day = False
                start_time = f"{dtstart[9:11]}:{dtstart[11:13]}"
            events_by_date.setdefault(date_key, []).append({
                "id": f"ics_{uid}_{date_key}",
                "title": summary,
                "date": date_key,
                "startTime": start_time,
                "endTime": "",
                "allDay": all_day,
                "color": cal_color or "#039be5",
                "colorId": "7",
                "calendarName": cal_name,
                "htmlLink": "",
                "source": "ics",
            })


def sync_events(year: int | None = None, month: int | None = None) -> dict:
    ensure_dirs()
    creds = load_client_credentials()
    user_cfg = load_user_config()
    ical_urls = user_cfg.get("icalUrls", []) if isinstance(user_cfg.get("icalUrls"), list) else []

    events_by_date: dict[str, list] = {}
    palette = dict(DEFAULT_GCAL_PALETTE)
    calendars_meta = []
    authenticated = False
    last_error = ""

    if creds and TOKEN_PATH.exists():
        try:
            access_token = get_valid_access_token()
            auth_headers = {"Authorization": f"Bearer {access_token}"}
            authenticated = True

            try:
                colors_resp = http_json(
                    "https://www.googleapis.com/calendar/v3/colors",
                    headers=auth_headers,
                )
                evt_colors = colors_resp.get("event", {})
                if isinstance(evt_colors, dict):
                    for cid, cinfo in evt_colors.items():
                        bg = cinfo.get("background")
                        if bg and cid in palette:
                            palette[cid] = {
                                "id": cid,
                                "name": palette[cid]["name"],
                                "hex": bg,
                            }
            except Exception:
                pass

            cal_list_resp = http_json(
                "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader",
                headers=auth_headers,
            )
            cal_items = cal_list_resp.get("items", [])
            included_ids = user_cfg.get("calendarIds")

            time_min, time_max = compute_sync_window(year, month)
            time_min_iso = time_min.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            time_max_iso = time_max.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

            for cal in cal_items:
                cal_id = cal.get("id")
                if not cal_id:
                    continue
                if isinstance(included_ids, list) and included_ids and cal_id not in included_ids:
                    continue
                if not isinstance(included_ids, list) and not cal.get("selected", True) and not cal.get("primary", False):
                    continue

                cal_name = cal.get("summaryOverride") or cal.get("summary") or "Calendar"
                cal_bg = cal.get("backgroundColor") or "#039be5"
                calendars_meta.append({
                    "id": cal_id,
                    "name": cal_name,
                    "color": cal_bg,
                    "primary": bool(cal.get("primary", False)),
                })

                q = urllib.parse.urlencode({
                    "singleEvents": "true",
                    "orderBy": "startTime",
                    "timeMin": time_min_iso,
                    "timeMax": time_max_iso,
                    "maxResults": "250",
                })
                encoded_cal_id = urllib.parse.quote(cal_id, safe="")
                ev_url = f"https://www.googleapis.com/calendar/v3/calendars/{encoded_cal_id}/events?{q}"
                try:
                    ev_resp = http_json(ev_url, headers=auth_headers)
                except Exception:
                    continue

                for item in ev_resp.get("items", []):
                    if item.get("status") == "cancelled":
                        continue
                    ev_id = item.get("id", "")
                    title = (item.get("summary") or "(No title)").strip()
                    color_id = str(item.get("colorId") or "")
                    ev_color = palette.get(color_id, {}).get("hex") or cal_bg or "#039be5"
                    html_link = item.get("htmlLink", "")

                    start_obj = item.get("start") or {}
                    end_obj = item.get("end") or {}

                    if "date" in start_obj:
                        try:
                            s_date = datetime.date.fromisoformat(start_obj["date"])
                            e_date = (
                                datetime.date.fromisoformat(end_obj["date"])
                                if "date" in end_obj
                                else s_date + datetime.timedelta(days=1)
                            )
                        except Exception:
                            continue
                        span_days = max(1, min(31, (e_date - s_date).days))
                        inferred_start, inferred_end, inferred_title = extract_event_timing(title)
                        for offset in range(span_days):
                            d_cur = s_date + datetime.timedelta(days=offset)
                            d_key = d_cur.isoformat()
                            if inferred_start and span_days == 1:
                                events_by_date.setdefault(d_key, []).append({
                                    "id": ev_id,
                                    "title": inferred_title,
                                    "date": d_key,
                                    "startTime": inferred_start,
                                    "endTime": inferred_end,
                                    "allDay": False,
                                    "color": ev_color,
                                    "colorId": color_id,
                                    "calendarName": cal_name,
                                    "htmlLink": html_link,
                                    "source": "gcal",
                                })
                            else:
                                events_by_date.setdefault(d_key, []).append({
                                    "id": ev_id,
                                    "title": title,
                                    "date": d_key,
                                    "startTime": "",
                                    "endTime": "",
                                    "allDay": True,
                                    "color": ev_color,
                                    "colorId": color_id,
                                    "calendarName": cal_name,
                                    "htmlLink": html_link,
                                    "source": "gcal",
                                })
                    elif "dateTime" in start_obj:
                        s_dt = parse_iso_datetime_to_local(start_obj["dateTime"])
                        e_dt = parse_iso_datetime_to_local(end_obj.get("dateTime", ""))
                        if not s_dt:
                            continue
                        d_key = s_dt.strftime("%Y-%m-%d")
                        s_time = s_dt.strftime("%H:%M")
                        e_time = e_dt.strftime("%H:%M") if e_dt else ""
                        events_by_date.setdefault(d_key, []).append({
                            "id": ev_id,
                            "title": title,
                            "date": d_key,
                            "startTime": s_time,
                            "endTime": e_time,
                            "allDay": False,
                            "color": ev_color,
                            "colorId": color_id,
                            "calendarName": cal_name,
                            "htmlLink": html_link,
                            "source": "gcal",
                        })

            try:
                tasks_resp = http_json(
                    "https://www.googleapis.com/tasks/v1/lists/@default/tasks?showCompleted=true&maxResults=100",
                    headers=auth_headers,
                )
                for gtask in tasks_resp.get("items", []):
                    t_title = (gtask.get("title") or "").strip()
                    due_raw = gtask.get("due") or ""
                    if not t_title or not due_raw or len(due_raw) < 10:
                        continue
                    d_key = due_raw[:10]
                    is_done = gtask.get("status") == "completed"
                    events_by_date.setdefault(d_key, []).append({
                        "id": "gtask_" + str(gtask.get("id", "")),
                        "title": t_title,
                        "date": d_key,
                        "startTime": "",
                        "endTime": "",
                        "allDay": True,
                        "done": is_done,
                        "color": "#33b679" if is_done else "#039be5",
                        "colorId": "2" if is_done else "7",
                        "calendarName": "Google Tasks",
                        "htmlLink": gtask.get("webViewLink", "https://tasks.google.com/"),
                        "source": "gtasks",
                    })
            except Exception:
                pass

        except Exception as e:
            last_error = str(e)

    for i_entry in ical_urls:
        url = i_entry.get("url") if isinstance(i_entry, dict) else str(i_entry)
        name = i_entry.get("name", "iCal") if isinstance(i_entry, dict) else "iCal"
        color = i_entry.get("color", "#039be5") if isinstance(i_entry, dict) else "#039be5"
        if not url:
            continue
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Omarchy-Calendar/1.0"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                parse_ics_events(resp.read().decode("utf-8", errors="replace"), name, color, events_by_date)
            authenticated = True
        except Exception as e:
            if not last_error:
                last_error = f"iCal sync error: {e}"

    for d_key, ev_list in events_by_date.items():
        ev_list.sort(key=lambda x: (0 if x.get("allDay") else 1, x.get("startTime") or "99:99", x.get("title") or ""))

    payload = {
        "version": 1,
        "hasCredentials": bool(creds),
        "credentialsPath": str(CREDENTIALS_PATH),
        "authenticated": authenticated,
        "syncedAt": int(time.time() * 1000) if authenticated and not last_error else read_json(CACHE_PATH).get("syncedAt", 0),
        "lastError": last_error,
        "palette": palette,
        "calendars": calendars_meta,
        "eventsByDate": events_by_date,
    }
    atomic_write_json(CACHE_PATH, payload)
    return {"ok": not bool(last_error), "authenticated": authenticated, "error": last_error, "dateCount": len(events_by_date)}


def _normalize_hhmm(h_str: str, m_str: str, ampm: str = "") -> str | None:
    try:
        h = int(h_str)
        m = int(m_str)
    except Exception:
        return None
    if m < 0 or m > 59:
        return None
    ap = (ampm or "").strip().lower()
    if ap in ("am", "a"):
        if h == 12:
            h = 0
        elif h < 0 or h > 11:
            return None
    elif ap in ("pm", "p"):
        if h < 12:
            h += 12
        elif h != 12:
            return None
    else:
        if h < 0 or h > 23:
            return None
    return f"{h:02d}:{m:02d}"


def extract_event_timing(raw_title: str, explicit_time: str = "") -> tuple[str, str, str]:
    """
    Extracts (start_hhmm, end_hhmm, clean_title) from an event title string.
    Supports:
      - "(10:30-14:00) Engineering test"
      - "[10:30 - 14:00] Engineering test"
      - "10:30-14:00 Engineering test"
      - "Engineering test (10:30-14:00)"
      - "(10:30) Engineering test" or "10:30 Engineering test"
      - Plain "Engineering test" -> ("", "", "Engineering test") (all-day event)
    """
    text = (raw_title or "").strip()
    if not text:
        return "", "", ""

    if explicit_time and re.match(r"^\d{1,2}:\d{2}(\s*-\s*\d{1,2}:\d{2})?$", explicit_time.strip()):
        parts = [p.strip() for p in explicit_time.split("-")]
        sh, sm = parts[0].split(":")
        s_norm = _normalize_hhmm(sh, sm)
        e_norm = ""
        if len(parts) > 1:
            eh, em = parts[1].split(":")
            e_norm = _normalize_hhmm(eh, em) or ""
        if s_norm:
            return s_norm, e_norm, text

    time_tok = r"(\d{1,2}):(\d{2})\s*(am|pm|AM|PM)?"
    sep_tok = r"\s*(?:[-–—]|to)\s*"

    # 1. Time range at the start: "(10:30-14:00) Engineering test" or "10:30-14:00 Engineering test"
    m = re.match(
        r"^[\(\[\s]*" + time_tok + sep_tok + time_tok + r"[\)\]\s]*[-:–—]?\s+(.+)$",
        text,
    )
    if m:
        s_norm = _normalize_hhmm(m.group(1), m.group(2), m.group(3) or "")
        e_norm = _normalize_hhmm(m.group(4), m.group(5), m.group(6) or "")
        cleaned = m.group(7).strip()
        if s_norm and e_norm and cleaned:
            return s_norm, e_norm, cleaned

    # 2. Time range at the end in brackets/parens: "Engineering test (10:30-14:00)"
    m = re.match(
        r"^(.+?)\s*[\(\[]\s*" + time_tok + sep_tok + time_tok + r"\s*[\)\]]\s*$",
        text,
    )
    if m:
        cleaned = m.group(1).strip()
        s_norm = _normalize_hhmm(m.group(2), m.group(3), m.group(4) or "")
        e_norm = _normalize_hhmm(m.group(5), m.group(6), m.group(7) or "")
        if s_norm and e_norm and cleaned:
            return s_norm, e_norm, cleaned

    # 3. Single start time at the start: "(10:30) Engineering test" or "10:30 Engineering test"
    m = re.match(
        r"^[\(\[\s]*" + time_tok + r"[\)\]\s]*[-:–—]?\s+(.+)$",
        text,
    )
    if m:
        s_norm = _normalize_hhmm(m.group(1), m.group(2), m.group(3) or "")
        cleaned = m.group(4).strip()
        if s_norm and cleaned:
            return s_norm, "", cleaned

    # 4. Single start time at the end in brackets/parens: "Engineering test (10:30)"
    m = re.match(
        r"^(.+?)\s*[\(\[]\s*" + time_tok + r"\s*[\)\]]\s*$",
        text,
    )
    if m:
        cleaned = m.group(1).strip()
        s_norm = _normalize_hhmm(m.group(2), m.group(3), m.group(4) or "")
        if s_norm and cleaned:
            return s_norm, "", cleaned

    return "", "", text


def build_event_start_end(date_key: str, start_time: str, end_time: str) -> tuple[dict, dict]:
    now_local = datetime.datetime.now().astimezone()
    tz_offset = now_local.strftime("%z")
    tz_formatted = f"{tz_offset[:3]}:{tz_offset[3:]}" if len(tz_offset) == 5 else "Z"

    if start_time and re.match(r"^\d{2}:\d{2}$", start_time):
        y, mo, d = [int(x) for x in date_key.split("-")]
        sh, sm = [int(x) for x in start_time.split(":")]
        start_dt = datetime.datetime(y, mo, d, sh, sm, 0, tzinfo=now_local.tzinfo)
        if end_time and re.match(r"^\d{2}:\d{2}$", end_time):
            eh, em = [int(x) for x in end_time.split(":")]
            end_dt = datetime.datetime(y, mo, d, eh, em, 0, tzinfo=now_local.tzinfo)
            if end_dt <= start_dt:
                # Overnight span (e.g. 22:00-01:00) advances end_dt to the next day
                end_dt += datetime.timedelta(days=1)
        else:
            end_dt = start_dt + datetime.timedelta(hours=1)
        return (
            {"dateTime": start_dt.strftime(f"%Y-%m-%dT%H:%M:00{tz_formatted}")},
            {"dateTime": end_dt.strftime(f"%Y-%m-%dT%H:%M:00{tz_formatted}")},
        )

    s_date = datetime.date.fromisoformat(date_key)
    e_date = s_date + datetime.timedelta(days=1)
    return {"date": s_date.isoformat()}, {"date": e_date.isoformat()}


def add_google_event(date_key: str, title: str, time_str: str = "", color_id: str = "7") -> dict:
    start_time, end_time, clean_title = extract_event_timing(title, time_str)
    if not clean_title:
        return {"ok": False, "error": "Event title is empty"}

    try:
        access_token = get_valid_access_token()
    except Exception as e:
        return {"ok": False, "error": str(e)}

    body: dict = {"summary": clean_title}
    if color_id and color_id in DEFAULT_GCAL_PALETTE:
        body["colorId"] = str(color_id)

    start_obj, end_obj = build_event_start_end(date_key, start_time, end_time)
    body["start"] = start_obj
    body["end"] = end_obj

    try:
        created = http_json(
            "https://www.googleapis.com/calendar/v3/calendars/primary/events",
            method="POST",
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json; charset=utf-8",
            },
            body=json.dumps(body).encode("utf-8"),
        )
    except urllib.error.HTTPError as e:
        err_text = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "error": f"Google Calendar API error ({e.code}): {err_text}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}

    y, mo, _ = [int(x) for x in date_key.split("-")]
    sync_events(year=y, month=mo)
    return {"ok": True, "eventId": created.get("id", "")}


def get_status() -> dict:
    ensure_dirs()
    payload = update_cache_status()
    total_events = sum(len(v) for v in payload.get("eventsByDate", {}).values())
    return {
        "ok": True,
        "hasCredentials": payload["hasCredentials"],
        "credentialsPath": payload["credentialsPath"],
        "authenticated": payload["authenticated"],
        "syncedAt": payload["syncedAt"],
        "eventCount": total_events,
        "lastError": payload["lastError"],
    }


def main():
    parser = argparse.ArgumentParser(description="Google Calendar & Local Tasks helper for Omarchy Clock")
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("status", help="Show credentials and sync status")
    sub.add_parser("auth", help="Run interactive browser OAuth2 login flow")

    p_sync = sub.add_parser("sync", help="Sync Google Calendar events into local state cache")
    p_sync.add_argument("--year", type=int, default=None)
    p_sync.add_argument("--month", type=int, default=None)

    p_add_ev = sub.add_parser("add-event", help="Create a new event on primary Google Calendar")
    p_add_ev.add_argument("--date", required=True, help="Date in YYYY-MM-DD format")
    p_add_ev.add_argument("--title", required=True, help="Event title (prefix with HH:MM for timed event)")
    p_add_ev.add_argument("--time", default="", help="Optional start time HH:MM")
    p_add_ev.add_argument("--color-id", default="7", help="Google Calendar colorId (1-11)")

    p_add_task = sub.add_parser("add-task", help="Add a local daily task for any date")
    p_add_task.add_argument("--date", required=True, help="Date in YYYY-MM-DD format")
    p_add_task.add_argument("--text", required=True, help="Task description")
    p_add_task.add_argument("--priority", default="normal", help="Priority: high | normal | low")
    p_add_task.add_argument("--color", default="", help="Optional custom hex color (#RRGGBB)")

    p_toggle_task = sub.add_parser("toggle-task", help="Toggle completion of a local task")
    p_toggle_task.add_argument("--id", required=True, help="Task ID")

    p_cycle_pri = sub.add_parser("cycle-priority", help="Cycle task priority (normal -> high -> low)")
    p_cycle_pri.add_argument("--id", required=True, help="Task ID")

    p_del_task = sub.add_parser("delete-task", help="Delete a local task")
    p_del_task.add_argument("--id", required=True, help="Task ID")

    args = parser.parse_args()
    cmd = args.cmd or "status"

    if cmd == "status":
        res = get_status()
    elif cmd == "auth":
        res = run_oauth_flow()
    elif cmd == "sync":
        res = sync_events(year=args.year, month=args.month)
    elif cmd == "add-event":
        res = add_google_event(args.date, args.title, args.time, args.color_id)
    elif cmd == "add-task":
        res = local_add_task(args.date, args.text, args.priority, args.color)
    elif cmd == "toggle-task":
        res = local_toggle_task(args.id)
    elif cmd == "cycle-priority":
        res = local_cycle_priority(args.id)
    elif cmd == "delete-task":
        res = local_delete_task(args.id)
    else:
        res = {"ok": False, "error": f"Unknown command: {cmd}"}

    print(json.dumps(res))
    sys.exit(0 if res.get("ok", True) else 1)


if __name__ == "__main__":
    main()
