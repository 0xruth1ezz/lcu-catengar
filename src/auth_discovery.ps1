# Embedded in the executable; stdout is a private credential pipe, never a log.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PSModulePath = $PSHOME + '\Modules'
try {
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='LeagueClientUx.exe' OR Name='LeagueClient.exe'" -OperationTimeoutSec 3)
} catch {
    if ($hasAdministratorToken) { exit 1 }
    exit 13
}
if ($processes.Count -eq 0) { exit 2 }

$permissionDenied = $false
foreach ($client in ($processes | Sort-Object CreationDate -Descending)) {
    if (!$client.CommandLine) { $permissionDenied = $true; continue }
    $port = [regex]::Match($client.CommandLine, '(?:^|\s)"?--app-port[= ]+"?(\d+)(?="|\s|$)')
    $token = [regex]::Match($client.CommandLine, '(?:^|\s)"?--remoting-auth-token[= ]+"?([^\s"]+)')
    if ($port.Success -and $token.Success) {
        $number = 0
        if (![int]::TryParse($port.Groups[1].Value, [ref]$number) -or $number -lt 1 -or $number -gt 65535) { continue }
        if ($token.Groups[1].Value.Length -gt 256) { continue }
        @{port=$number; token=$token.Groups[1].Value; pid=$client.ProcessId} | ConvertTo-Json -Compress
        exit 0
    }
}

# The UX process can be absent while the League backend still owns the LCU.
# Only inspect a lockfile beside an observed client executable, with a live PID.
foreach ($client in ($processes | Sort-Object CreationDate -Descending)) {
    $executablePath = $client.ExecutablePath
    if (!$executablePath) {
        $executablePath = ($clientPaths | Where-Object { $_.pid -eq $client.ProcessId } | Select-Object -First 1).path
    }
    if (!$executablePath) { $permissionDenied = $true; continue }
    $stream = $null
    try {
        $path = [IO.Path]::Combine([IO.Path]::GetDirectoryName($executablePath), 'lockfile')
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt 4096) { continue }
        $bytes = [byte[]]::new(4097)
        $count = 0
        while ($count -lt $bytes.Length) {
            $read = $stream.Read($bytes, $count, $bytes.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -eq 0 -or $count -gt 4096) { continue }
        $parts = [Text.Encoding]::UTF8.GetString($bytes, 0, $count).TrimEnd([char[]]"`r`n").Split(':')
        if ($parts.Count -ne 5 -or $parts[0] -ne 'LeagueClient' -or $parts[4] -ne 'https') { continue }
        $owner = 0; $number = 0
        if (![uint32]::TryParse($parts[1], [ref]$owner) -or $owner -eq 0) { continue }
        if (![int]::TryParse($parts[2], [ref]$number) -or $number -lt 1 -or $number -gt 65535) { continue }
        if (!($processes | Where-Object { $_.ProcessId -eq $owner -and $_.Name -eq 'LeagueClient.exe' })) { continue }
        if ($parts[3].Length -lt 1 -or $parts[3].Length -gt 256 -or $parts[3] -match '[\s\x00]') { continue }
        @{port=$number; token=$parts[3]; pid=$owner} | ConvertTo-Json -Compress
        exit 0
    } catch [UnauthorizedAccessException] {
        $permissionDenied = $true
    } catch [IO.IOException] {
        # Missing, locked or partially written files are retried on the next poll.
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}
if ($permissionDenied -and !$hasAdministratorToken) { exit 13 }
exit 3
