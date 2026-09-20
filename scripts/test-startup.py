"""Smoke-test a portable GUI in an isolated profile, without a UAC helper."""

import argparse
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


@contextmanager
def startup_directory():
    directory = tempfile.TemporaryDirectory(prefix="catengar-startup-")
    root = Path(directory.name).resolve()
    if root.parent != Path(tempfile.gettempdir()).resolve() or not root.name.startswith("catengar-startup-"):
        raise RuntimeError("Refusing to clean an unexpected temporary directory")
    try:
        yield root
    finally:
        # A crashed app can leave its short-lived credential probe holding the
        # working directory. Let it finish without touching other processes.
        deadline = time.monotonic() + 15
        while True:
            try:
                directory.cleanup()
                break
            except PermissionError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path("zig-out/bin"))
    args = parser.parse_args()
    source = args.build_dir.resolve()
    for name in ("catengar.exe", "WebView2Loader.dll"):
        if not (source / name).is_file():
            raise RuntimeError(f"Missing startup dependency: {source / name}")

    with startup_directory() as root:
        app = root / "portable space's [test]"
        app.mkdir()
        # Deliberately omit the administrator helper: startup must render an
        # actionable disconnected state without opening a UAC prompt. Separate
        # test-auth covers the helper; package tests verify all shipped files.
        for name in ("catengar.exe", "WebView2Loader.dll"):
            shutil.copy2(source / name, app / name)
        data = root / "data" / "LoLRengar"
        data.mkdir(parents=True)
        (data / "settings.json").write_text(json.dumps({
            "version": 1, "auto_accept": False, "auto_pick": False, "priority": [107],
        }), encoding="utf-8")
        # Exercise startup restoration and portrait decoding without LCU data.
        portrait = data / "cache" / "offline-fixture" / "champion-107.png"
        portrait.parent.mkdir(parents=True)
        shutil.copy2(Path(__file__).resolve().parent.parent / "assets" / "catengar-icon.png", portrait)
        (data / "priority-champions.json").write_text(json.dumps({
            "version": 1,
            "champions": [{
                "id": 107, "name": "雷恩加尔", "alias": "Rengar",
                "asset": "/lol-game-data/assets/v1/champion-icons/107.png",
                "portrait": "cache/offline-fixture/champion-107.png",
            }],
        }, ensure_ascii=False), encoding="utf-8")
        env = os.environ.copy()
        env["LOCALAPPDATA"] = str(root / "data")
        env["APPDATA"] = str(root / "roaming")
        log_path = root / "startup.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(app / "catengar.exe")], cwd=app, env=env,
                stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW,
            )
            visible = False
            user32 = ctypes.WinDLL("user32", use_last_error=True)
            callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
            user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
            user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
            user32.IsWindowVisible.argtypes = [wintypes.HWND]

            @callback_type
            def visit(hwnd, _):
                nonlocal visible
                pid = wintypes.DWORD()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                if pid.value == process.pid and user32.IsWindowVisible(hwnd):
                    visible = True
                return True

            try:
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    code = process.poll()
                    if code is not None:
                        detail = log_path.read_text(encoding="utf-8", errors="replace")[-4000:]
                        raise RuntimeError(f"Startup exited early: {code} (0x{code & 0xffffffff:08x})\n{detail}")
                    user32.EnumWindows(visit, 0)
                    time.sleep(0.1)
                if not visible:
                    raise RuntimeError("Application stayed alive but never showed its window")
            finally:
                # Stop only the exact isolated process created by this test.
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=10)
        print("PASS: portable app displayed its window and survived startup with an isolated offline priority cache")


if __name__ == "__main__":
    main()
