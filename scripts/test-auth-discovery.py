"""Run the embedded discovery script against fake processes and lockfiles only."""

import base64
import ctypes
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    system = ctypes.create_unicode_buffer(32768)
    if not ctypes.windll.kernel32.GetSystemDirectoryW(system, len(system)):
        raise RuntimeError("Cannot locate Windows PowerShell")
    powershell = Path(system.value) / "WindowsPowerShell/v1.0/powershell.exe"
    script = (Path(__file__).resolve().parent.parent / "src/auth_discovery.ps1").read_text()
    count = 0
    with tempfile.TemporaryDirectory(prefix="catengar-discovery-") as temporary:
        directory = Path(temporary) / "客户端 space's [fixture]"
        directory.mkdir()
        lockfile = directory / "lockfile"

        def process(name="LeagueClient.exe", pid=42, command="LeagueClient.exe"):
            return dict(Name=name, ProcessId=pid, CommandLine=command,
                        ExecutablePath=str(directory / name), CreationDate="2026-09-20")

        def check(name, processes, code, expected=None, lock=None, hold_open=False, native_paths=(), elevated=False):
            nonlocal count
            if lock is None:
                lockfile.unlink(missing_ok=True)
            else:
                lockfile.write_text(lock, encoding="utf-8")
            fixture = base64.b64encode(json.dumps(processes).encode()).decode()
            paths = base64.b64encode(json.dumps(native_paths).encode()).decode()
            # Override only process enumeration, so production parsing, bounded
            # file reading and exit codes run unchanged. Never query real clients.
            prelude = f"""
$clientPaths = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{paths}')) | ConvertFrom-Json
$hasAdministratorToken = {'$true' if elevated else '$false'}
function Get-CimInstance {{
    param($ClassName, $Filter, $OperationTimeoutSec)
    if ($Filter -notmatch 'LeagueClientUx.exe' -or $Filter -notmatch 'LeagueClient.exe') {{ throw 'Missing client process type' }}
    $fixtureProcesses = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{fixture}')) | ConvertFrom-Json
    foreach ($fixtureProcess in $fixtureProcesses) {{ $fixtureProcess }}
}}
"""
            if hold_open:
                encoded_path = base64.b64encode(str(lockfile).encode()).decode()
                prelude += f"""
$fixturePath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{encoded_path}'))
$fixtureWriter = [IO.FileStream]::new($fixturePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
"""
            result = subprocess.run(
                [str(powershell), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", prelude + script],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
            assert result.returncode == code, f"{name}: expected exit {code}, got {result.returncode}"
            if expected is not None:
                assert json.loads(result.stdout) == expected, f"{name}: incorrect credential selection"
            else:
                assert not result.stdout, f"{name}: unexpected credential output"
            assert not result.stderr, f"{name}: unexpected PowerShell error"
            count += 1

        credential = dict(port=54321, token="fixture-token", pid=42)
        check("client not running", [], 2)
        for name in ("LeagueClientUx.exe", "LeagueClient.exe"):
            check(name, [process(name, command=f'{name} --app-port=54321 --remoting-auth-token=fixture-token')], 0, credential)
        check("quoted flags", [process(command='client "--app-port=54321" --remoting-auth-token "fixture-token"')], 0, credential)
        check("Riot credentials are not LCU credentials", [process(command='client --riotclient-app-port=54321 --riotclient-auth-token=wrong')], 3)
        check("client still starting", [process()], 3)
        unreadable = process(command=None)
        unreadable["ExecutablePath"] = None
        check("permission required", [unreadable], 13)
        valid = "LeagueClient:42:54321:fixture-token:https"
        check("backend lockfile with active writer", [process()], 0, credential, valid, True)
        check("lockfile readable without process command line", [process(command=None)], 0, credential, valid)
        check("trailing newline", [process()], 0, credential, valid + "\r\n")
        check("empty startup lockfile", [process()], 3, lock="")
        check("stale PID", [process()], 3, lock=valid.replace(":42:", ":41:"))
        check("wrong protocol", [process()], 3, lock=valid.replace(":https", ":http"))
        check("oversized lockfile", [process()], 3, lock="x" * 4097)
        check("invalid lockfile port", [process()], 3, lock=valid.replace(":54321:", ":70000:"))
        check("malformed command port falls back", [process(command="client --app-port=999999999999 --remoting-auth-token=wrong")], 0, credential, valid)
        check("empty token", [process()], 3, lock=valid.replace("fixture-token", ""))
        check("token contains newline", [process()], 3, lock=valid.replace("fixture-token", "fixture\ntoken"))
        check("unrelated lockfile", [process()], 3, lock=valid.replace("LeagueClient:", "RiotClient:"))
        check("UX missing flags falls back to backend", [process("LeagueClientUx.exe", 43), process(command="client --app-port=54321 --remoting-auth-token=fixture-token")], 0, credential)
        check("native path fallback when WMI hides path", [unreadable], 0, credential, valid,
              native_paths=[dict(pid=42, path=str(directory / "LeagueClient.exe"))])
        check("native path for unrelated PID is ignored", [unreadable], 13, lock=valid,
              native_paths=[dict(pid=41, path=str(directory / "LeagueClient.exe"))])
        check("actual admin is not asked to authorize again", [unreadable], 3, lock="", elevated=True,
              native_paths=[dict(pid=42, path=str(directory / "LeagueClient.exe"))])
    print(f"Discovery: {count} scenarios passed (fake processes and credentials only).")


if __name__ == "__main__":
    main()
