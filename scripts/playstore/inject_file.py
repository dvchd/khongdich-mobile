#!/usr/bin/env python3
"""Inject local files into Play Console file inputs (AAB upload hoặc ảnh store listing).

Cách hoạt động:
  1. fetch mode (mặc định): dùng local_serve.py (http://127.0.0.1:8899, có CORS+PNA)
     để trang Play Console fetch file rồi dispatch vào input[type=file] — nhanh.
  2. chunked mode (--chunked hoặc tự fallback khi fetch lỗi): đẩy base64 theo chunk
     qua `opencli browser <session> eval` rồi lắp File — chậm nhưng không cần server.

Usage:
  inject_file.py aab <file.aab>                    # inject vào input tải gói ứng dụng
  inject_file.py store <file.png> <btn_idx> [name] # inject ảnh: 0=icon, 1=feature, 2=screenshots
Options:
  --profile PROFILE   profile opencli (env OPENCLI_PROFILE, default vfhyu9r7)
  --session SESSION   browser session opencli (env OPENCLI_SESSION, default gp)
  --server URL        base URL của local_serve (default http://127.0.0.1:8899)
  --port PORT         port cho local_serve tự khởi động (default 8899)
  --chunked           bỏ qua fetch, luôn dùng chunked base64
"""
import argparse
import base64
import subprocess
import sys
import time

CHUNK = 900 * 1024
STORE_BUTTON_LABEL = "Thêm thành phần"


def run_eval(profile: str, session: str, js: str, timeout: int = 300) -> str:
    out = subprocess.run(
        ["opencli", "--profile", profile, "browser", session, "eval", js],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return (out.stdout or "").strip() + (" | " + (out.stderr or "").strip() if out.stderr else "")


def ensure_server(server: str, port: int, file_path: str) -> bool:
    import os
    import urllib.request
    try:
        with urllib.request.urlopen(server + "/", timeout=2):
            return True
    except Exception:
        pass
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "local_serve.py")
    serve_root = os.path.dirname(os.path.abspath(file_path))
    try:
        subprocess.Popen(
            [sys.executable, script, serve_root, str(port)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return False
    time.sleep(1)
    try:
        with urllib.request.urlopen(server + "/", timeout=2):
            return True
    except Exception:
        return False


def fetch_inject(profile, session, server, name, selector_js) -> str:
    js = (
        "(async()=>{"
        f"const url='{server}/{name}';"
        "const input=" + selector_js + ";"
        "if(!input)return 'NO INPUT';"
        "try{"
        "const r=await fetch(url);"
        "if(!r.ok)return 'FETCH FAIL '+r.status;"
        "const buf=await r.arrayBuffer();"
        f"const f=new File([buf],'{name}',{{type:'application/octet-stream'}});"
        "const dt=new DataTransfer();dt.items.add(f);"
        "input.files=dt.files;"
        "input.dispatchEvent(new Event('change',{bubbles:true}));"
        "return 'dispatched size='+f.size;"
        "}catch(e){return 'ERR '+e.message;}"
        "})()"
    )
    return run_eval(profile, session, js)


def chunked_inject(profile, session, file_path, name, selector_js) -> str:
    with open(file_path, "rb") as fh:
        b64 = base64.b64encode(fh.read()).decode()
    js = f"(function(){{const input={selector_js};return input?('INPUT accept='+(input.getAttribute('accept')||'')):'NO INPUT';}})()"
    if "NO INPUT" in run_eval(profile, session, js):
        return "NO INPUT"
    n_chunks = len(b64) // CHUNK + 1
    for i in range(0, len(b64), CHUNK):
        chunk = b64[i : i + CHUNK]
        js = (
            "(function(){window.__up=window.__up||{};"
            "window.__up.b=(window.__up.b||'')+'" + chunk + "';"
            "return window.__up.b.length;})()"
        )
        r = run_eval(profile, session, js)
        if i == 0 or (i // CHUNK) % 20 == 0:
            print(f"  chunk {i // CHUNK}/{n_chunks} -> {r}", flush=True)
    final = (
        "(function(){const b64=window.__up.b;window.__up.b='';"
        "const bin=atob(b64);const bytes=new Uint8Array(bin.length);"
        "for(let i=0;i<bin.length;i++){bytes[i]=bin.charCodeAt(i);}"
        f"const f=new File([bytes],'{name}',{{type:'application/octet-stream'}});"
        "const dt=new DataTransfer();dt.items.add(f);"
        f"const input={selector_js};"
        "if(!input)return 'NO INPUT';"
        "input.files=dt.files;"
        "input.dispatchEvent(new Event('change',{bubbles:true}));"
        "return 'dispatched size='+f.size;})()"
    )
    return run_eval(profile, session, final, timeout=600)


AAB_SELECTOR = (
    "([...document.querySelectorAll('input[type=file]')]"
    ".find(i=>(i.getAttribute('accept')||'').includes('.aab'))||null)"
)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["aab", "store"])
    ap.add_argument("file_path")
    ap.add_argument("btn_idx", nargs="?", type=int, default=None)
    ap.add_argument("name", nargs="?", default=None)
    ap.add_argument("--profile", default="vfhyu9r7")
    ap.add_argument("--session", default="gp")
    ap.add_argument("--server", default="http://127.0.0.1:8899")
    ap.add_argument("--port", type=int, default=8899)
    ap.add_argument("--chunked", action="store_true")
    args = ap.parse_args()

    name = args.name or args.file_path.rsplit("/", 1)[-1]

    if args.mode == "aab":
        selector_js = AAB_SELECTOR
    else:
        if args.btn_idx is None:
            sys.exit("store mode cần <btn_idx>: 0=icon, 1=feature graphic, 2=screenshots")
        label = STORE_BUTTON_LABEL
        click_js = (
            "(function(){const els=[...document.querySelectorAll('button,a')]"
            ".filter(e=>e.offsetParent!==null&&(e.innerText||'').replace(/\\s+/g,' ').trim()==='" + label + "');"
            f"if(!els[{args.btn_idx}])return 'btn missing';"
            f"els[{args.btn_idx}].click();return 'clicked idx {args.btn_idx}';}})()"
        )
        print("[*] clicking add button:", run_eval(args.profile, args.session, click_js, timeout=120), flush=True)
        time.sleep(3)
        selector_js = "([...document.querySelectorAll('input[type=file]')].pop()||null)"

    if not args.chunked and ensure_server(args.server, args.port, args.file_path):
        print("[*] fetch mode", flush=True)
        res = fetch_inject(args.profile, args.session, args.server, name, selector_js)
        if res.startswith("dispatched"):
            print(res, flush=True)
            return
        print(f"[*] fetch lỗi ({res}) → fallback chunked", flush=True)

    print("[*] chunked mode", flush=True)
    res = chunked_inject(args.profile, args.session, args.file_path, name, selector_js)
    print(res, flush=True)


if __name__ == "__main__":
    main()
