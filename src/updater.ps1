param([ValidateSet('', 'Check', 'Prepare', 'Install')][string]$Mode = '', [string]$Request = '')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:PSModulePath = $PSHOME + '\Modules'
$script:Files = @('catengar.exe', 'catengar-auth.exe', 'catengar-diagnose.exe', 'WebView2Loader.dll', 'WebView2-LICENSE.txt', 'README.md')
$script:Repository = '0xruth1ezz/lcu-catengar'

function Write-JsonFile($Path, $Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-StableVersion([string]$Text) {
    if ($Text -cnotmatch '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'InvalidVersion' }
    $version = [version]$Text.TrimStart('v')
    if ($version.Major -gt 65535 -or $version.Minor -gt 65535 -or $version.Build -gt 65535) { throw 'InvalidVersion' }
    return $version
}

function Read-Release($Release, [string]$Current) {
    if ($Release.draft -ne $false -or $Release.prerelease -ne $false) { throw 'InvalidRelease' }
    $version = Get-StableVersion ([string]$Release.tag_name)
    if ($version -le (Get-StableVersion $Current)) { return @{ status = 'current' } }
    if ($Release.tag_name -cne "v$version") { throw 'InvalidRelease' }
    $name = "catengar-v$version-windows-x64.zip"
    $assets = @($Release.assets | Where-Object { $_.name -ceq $name -and $_.state -eq 'uploaded' })
    if ($assets.Count -ne 1) { throw 'MissingAsset' }
    $asset = $assets[0]
    $url = "https://github.com/$script:Repository/releases/download/v$version/$name"
    if ($asset.browser_download_url -cne $url -or $asset.digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'UnverifiedAsset' }
    if ([long]$asset.size -le 0 -or [long]$asset.size -gt 134217728) { throw 'InvalidSize' }
    return @{ status = 'available'; version = "$version"; url = $url; sha256 = $asset.digest.Substring(7); size = [long]$asset.size }
}

# Redirects are validated individually; TLS validation is never disabled.
function Get-HttpsFile([string]$Url, [string]$Destination, [long]$Limit) {
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(90)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Catengar-Updater/1.0')
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        for ($redirect = 0; $redirect -lt 6; $redirect++) {
            $uri = [uri]$Url
            if ($uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
                $uri.Host -notin @('api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com')) { throw 'UntrustedUrl' }
            $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try {
                $status = [int]$response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    if (!$response.Headers.Location) { throw 'NetworkError' }
                    $Url = [uri]::new($uri, $response.Headers.Location).AbsoluteUri
                    continue
                }
                if ($status -eq 404) { throw 'NoRelease' }
                if ($status -eq 403 -or $status -eq 429) { throw 'RateLimited' }
                if ($status -ne 200) { throw 'NetworkError' }
                if ($response.Content.Headers.ContentLength -gt $Limit) { throw 'InvalidSize' }
                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $buffer = New-Object byte[] 65536
                    [long]$total = 0
                    while ($true) {
                        $read = $inputStream.ReadAsync($buffer, 0, $buffer.Length)
                        if (!$read.Wait(15000)) { throw 'NetworkTimeout' }
                        $count = $read.GetAwaiter().GetResult()
                        if ($count -eq 0) { break }
                        $total += $count
                        if ($total -gt $Limit -or $watch.Elapsed.TotalSeconds -gt 180) { throw 'InvalidSize' }
                        $outputStream.Write($buffer, 0, $count)
                    }
                } finally { $outputStream.Dispose(); $inputStream.Dispose() }
                return
            } finally { $response.Dispose() }
        }
        throw 'NetworkError'
    } finally { $client.Dispose(); $handler.Dispose() }
}

function Assert-Directory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (![IO.Path]::IsPathRooted($Path) -or !(Test-Path -LiteralPath $full -PathType Container)) { throw 'InvalidDirectory' }
    if ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'InvalidDirectory' }
    return $full
}

function Assert-Stage([string]$Stage, [string]$Target) {
    $targetPath = Assert-Directory $Target
    $stagePath = Assert-Directory $Stage
    if ([IO.Path]::GetDirectoryName($stagePath) -ine $targetPath -or
        [IO.Path]::GetFileName($stagePath) -cnotmatch '^\.catengar-update-[a-f0-9]{32}$') { throw 'InvalidStage' }
    return $stagePath
}

function Expand-Update([string]$Archive, [string]$Stage, $Release) {
    if ((Get-Item -LiteralPath $Archive).Length -ne [long]$Release.size -or
        (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ine $Release.sha256) { throw 'ChecksumMismatch' }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $hashes = @{}
    try {
        if ($zip.Entries.Count -ne $script:Files.Count) { throw 'InvalidArchive' }
        [long]$total = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name -cnotin $script:Files -or $hashes.ContainsKey($name) -or $entry.Length -le 0) { throw 'InvalidArchive' }
            $total += $entry.Length
            if ($total -gt 536870912 -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'InvalidArchive' }
            $path = Join-Path $Stage $name
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $false)
            $hashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
        foreach ($name in $script:Files) { if (!$hashes.ContainsKey($name)) { throw 'InvalidArchive' } }
        $version = Get-StableVersion $Release.version
        $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $Stage 'catengar.exe'))
        if ($fileVersion.FileMajorPart -ne $version.Major -or $fileVersion.FileMinorPart -ne $version.Minor -or
            $fileVersion.FileBuildPart -ne $version.Build) { throw 'VersionMismatch' }
    } finally { $zip.Dispose() }
    Write-JsonFile (Join-Path $Stage 'manifest.json') @{ version = $Release.version; hashes = $hashes }
}

# Only the known files inside an explicitly validated update directory are removed.
function Remove-Stage([string]$Stage, [string]$Target) {
    $stagePath = Assert-Stage $Stage $Target
    $backup = Join-Path $stagePath 'backup'
    if (Test-Path -LiteralPath $backup) {
        [void](Assert-Directory $backup)
        foreach ($name in $script:Files) {
            $file = Join-Path $backup $name
            if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
        }
        [IO.Directory]::Delete($backup, $false)
    }
    foreach ($name in ($script:Files + @('package.zip', 'manifest.json'))) {
        $file = Join-Path $stagePath $name
        if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
    }
    [IO.Directory]::Delete($stagePath, $false)
}

function Move-Retry([string]$Source, [string]$Destination) {
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        try { Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop; return }
        catch { if ($attempt -eq 39) { throw }; Start-Sleep -Milliseconds 250 }
    }
}

function Apply-Update([string]$Stage, [string]$Target) {
    $stagePath = Assert-Stage $Stage $Target
    $manifest = Get-Content -LiteralPath (Join-Path $stagePath 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in $script:Files) {
        $path = Join-Path $stagePath $name
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $manifest.hashes.$name) { throw 'ChecksumMismatch' }
        $destination = Join-Path $Target $name
        if ((Test-Path -LiteralPath $destination) -and
            ((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'InvalidDirectory' }
    }
    $backup = Join-Path $stagePath 'backup'
    [void][IO.Directory]::CreateDirectory($backup)
    $installed = [Collections.Generic.List[string]]::new()
    try {
        foreach ($name in $script:Files) {
            $destination = Join-Path $Target $name
            if (Test-Path -LiteralPath $destination) { Move-Retry $destination (Join-Path $backup $name) }
            Move-Retry (Join-Path $stagePath $name) $destination
            $installed.Add($name)
        }
    } catch {
        $installError = $_.Exception.Message
        try { Restore-Update $stagePath $Target $installed.ToArray() }
        catch { throw 'RollbackFailed' }
        throw ('InstallFailed: ' + $installError)
    }
}

function Restore-Update([string]$Stage, [string]$Target, [string[]]$Installed) {
    [void](Assert-Stage $Stage $Target)
    foreach ($name in $script:Files) {
        $old = Join-Path (Join-Path $Stage 'backup') $name
        $destination = Join-Path $Target $name
        if ($name -in $Installed -and (Test-Path -LiteralPath $destination -PathType Leaf)) { Remove-Item -LiteralPath $destination -Force }
        if (Test-Path -LiteralPath $old -PathType Leaf) { Move-Retry $old $destination }
    }
}

function Assert-GameIdle {
    if (Get-Process -Name 'League of Legends' -ErrorAction SilentlyContinue) { throw 'GameRunning' }
}

function Start-Catengar([string]$Executable, [string]$Directory) {
    # ProcessStartInfo treats the working directory literally, including [] and
    # apostrophes; PowerShell Start-Process resolves it as a wildcard path.
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = [Diagnostics.Process]::Start($start)
    $process.Dispose()
}

function Get-ErrorMessage([string]$Code) {
    switch -Regex ($Code) {
        'NoRelease' { return '暂无公开发布的正式版，请稍后再检查。' }
        'RateLimited' { return 'GitHub 请求暂时受限，请稍后重试。' }
        'MissingAsset|UnverifiedAsset|InvalidRelease' { return '新版本尚无完整、可校验的更新包，请稍后重试。' }
        'ChecksumMismatch|InvalidArchive|InvalidSize|VersionMismatch|InvalidVersion|UntrustedUrl' { return '更新包校验未通过，原版本未被替换。请点击“检查更新”后重试。' }
        'GameRunning' { return '请结束对局后再更新。' }
        'RollbackFailed' { return '更新恢复未完成，请从更新目录的 backup 文件夹恢复原文件。' }
        'InstallFailed' { return '替换文件失败，已恢复原版本。请关闭占用文件的程序后重试。' }
        'Access.*denied|UnauthorizedAccess|拒绝访问|访问被拒绝' { return '程序目录不可写，请将完整程序移到可写目录后重试。' }
        'ParentTimeout|Cancelled' { return '更新未执行，程序文件保持不变。请重试。' }
        default { return '更新服务暂不可用，请检查网络连接或稍后重试。' }
    }
}

if ($Mode) {
    $requestData = Get-Content -LiteralPath $Request -Raw -Encoding UTF8 | ConvertFrom-Json
    $target = Assert-Directory ([IO.Path]::GetDirectoryName($requestData.executable))
    $result = @{ status = 'error'; message = '更新未完成，请重试。' }
    try {
        switch ($Mode) {
            'Check' {
                $metadata = $Request + '.release'
                try {
                    Get-HttpsFile "https://api.github.com/repos/$script:Repository/releases/latest" $metadata 2097152
                    $release = Get-Content -LiteralPath $metadata -Raw -Encoding UTF8 | ConvertFrom-Json
                    $result = Read-Release $release $requestData.current
                } finally { if (Test-Path -LiteralPath $metadata) { Remove-Item -LiteralPath $metadata } }
            }
            'Prepare' {
                # Revalidate the exact tag and digest before downloading executable content.
                $metadata = $Request + '.release'
                $version = Get-StableVersion $requestData.version
                try {
                    Get-HttpsFile "https://api.github.com/repos/$script:Repository/releases/tags/v$version" $metadata 2097152
                    $release = Read-Release (Get-Content -LiteralPath $metadata -Raw -Encoding UTF8 | ConvertFrom-Json) $requestData.current
                    if ($release.status -ne 'available' -or $release.version -cne $requestData.version -or $release.sha256 -cne $requestData.sha256) { throw 'UnverifiedAsset' }
                } finally { if (Test-Path -LiteralPath $metadata) { Remove-Item -LiteralPath $metadata } }
                $stage = Join-Path $target ('.catengar-update-' + [guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory($stage)
                try {
                    $archive = Join-Path $stage 'package.zip'
                    Get-HttpsFile $release.url $archive $release.size
                    Expand-Update $archive $stage $release
                    $result = @{ status = 'ready'; stage = $stage; version = $release.version }
                } catch { Remove-Stage $stage $target; throw }
            }
            'Install' {
                [void](Assert-Stage $requestData.stage $target)
                Assert-GameIdle
                $parent = [Diagnostics.Process]::GetProcessById([int]$requestData.parent)
                [void]$parent.Handle
                if ([IO.Path]::GetFullPath($parent.MainModule.FileName) -ine [IO.Path]::GetFullPath($requestData.executable)) { throw 'InvalidParent' }
                Write-JsonFile ($Request + '.ready') @{ ready = $true }
                $deadline = [DateTime]::UtcNow.AddSeconds(15)
                while (!(Test-Path -LiteralPath ($Request + '.commit'))) {
                    if ([DateTime]::UtcNow -gt $deadline -or $parent.HasExited) { throw 'Cancelled' }
                    Start-Sleep -Milliseconds 100
                }
                if (!$parent.WaitForExit(60000)) { throw 'ParentTimeout' }
                Assert-GameIdle
                Apply-Update $requestData.stage $target
                $result = @{ status = 'updated'; message = "已更新至 v$($requestData.version)。" }
                Write-JsonFile $requestData.receipt $result
                try { Start-Catengar $requestData.executable $target }
                catch {
                    $launchError = $_.Exception.Message
                    Restore-Update $requestData.stage $target $script:Files
                    throw ('InstallFailed: restart: ' + $launchError)
                }
                # Cleanup failure must not turn a completed update into a rollback.
                try { Remove-Stage $requestData.stage $target } catch {}
            }
        }
    } catch {
        $result = @{ status = 'error'; message = Get-ErrorMessage $_.Exception.ToString() }
        if ($Mode -eq 'Install' -and $parent -and $parent.HasExited) {
            Write-JsonFile $requestData.receipt $result
            try { Start-Catengar $requestData.executable $target } catch {}
        }
    }
    Write-JsonFile ($Request + '.result') $result
}
