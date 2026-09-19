$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $projectRoot 'src/updater.ps1'))))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('catengar-update-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:Passed = 0

function Assert($Value, [string]$Message) {
    if (!$Value) { throw $Message }
    $script:Passed++
}
function Reject([scriptblock]$Action, [string]$Expected) {
    $caught = $false
    $actual = 'no error'
    try { & $Action } catch { $actual = $_.Exception.Message; $caught = $actual -match $Expected }
    Assert $caught "Expected rejection: $Expected; got: $actual"
}
function New-Release {
    return (ConvertFrom-Json '{"draft":false,"prerelease":false,"tag_name":"v0.1.2","assets":[{"name":"catengar-v0.1.2-windows-x64.zip","state":"uploaded","size":100,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","browser_download_url":"https://github.com/0xruth1ezz/lcu-catengar/releases/download/v0.1.2/catengar-v0.1.2-windows-x64.zip"}]}')
}
function New-Stage([string]$Target) {
    $stage = Join-Path $Target ('.catengar-update-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    return $stage
}
function Zip-Files([string]$Path, [string[]]$Names) {
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Names) {
            $entry = $zip.CreateEntry($name)
            $stream = $entry.Open()
            try {
                $data = if ($name.EndsWith('.exe') -or $name.EndsWith('.dll')) { [IO.File]::ReadAllBytes($script:NewExe) } else { [Text.Encoding]::UTF8.GetBytes('fixture') }
                $stream.Write($data, 0, $data.Length)
            } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    return @{ version = '0.1.2'; size = (Get-Item -LiteralPath $Path).Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}

try {
    $release = New-Release
    Assert ((Read-Release $release '0.1.1').status -eq 'available') 'New version not detected'
    Assert ((Read-Release $release '0.1.2').status -eq 'current') 'Equal version not current'
    Assert ((Read-Release $release '0.2.0').status -eq 'current') 'Downgrade offered'
    foreach ($field in @('draft', 'prerelease')) {
        $release = New-Release; $release.$field = $true
        Reject { Read-Release $release '0.1.1' } 'InvalidRelease'
    }
    foreach ($version in @('v0.1.2-beta', 'v01.1.2', 'v0.1.2/../../bad', 'v0.1.65536')) {
        $release = New-Release; $release.tag_name = $version
        Reject { Read-Release $release '0.1.1' } 'InvalidVersion'
    }
    $release = New-Release; $release.assets[0].digest = $null
    Reject { Read-Release $release '0.1.1' } 'UnverifiedAsset'
    $release = New-Release; $release.assets[0].browser_download_url = 'https://example.com/evil.zip'
    Reject { Read-Release $release '0.1.1' } 'UnverifiedAsset'
    $release = New-Release; $release.assets[0].name = 'catengar.exe'
    Reject { Read-Release $release '0.1.1' } 'MissingAsset'
    $release = New-Release; $release.assets[0].size = 134217729
    Reject { Read-Release $release '0.1.1' } 'InvalidSize'
    Reject { Get-HttpsFile 'http://github.com/evil' (Join-Path $testRoot 'unused') 100 } 'UntrustedUrl'
    Reject { Get-HttpsFile 'https://example.com/evil' (Join-Path $testRoot 'unused') 100 } 'UntrustedUrl'

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $script:NewExe = Join-Path $testRoot 'fixture.exe'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Threading;
[assembly: AssemblyFileVersion("0.1.2.0")]
public class UpdateFixture {
    public static void Main(string[] args) {
        if (args.Length > 0) Thread.Sleep(Int32.Parse(args[0]));
        else File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "restarted.txt"), "ok");
    }
}
'@ -OutputAssembly $script:NewExe -OutputType ConsoleApplication
    $target = Join-Path $testRoot "portable space's [test]"
    [void][IO.Directory]::CreateDirectory($target)
    $stage = New-Stage $target
    $archive = Join-Path $stage 'package.zip'
    $meta = Zip-Files $archive $script:Files
    $wrong = $meta.Clone(); $wrong.sha256 = 'a' * 64
    Reject { Expand-Update $archive $stage $wrong } 'ChecksumMismatch'
    Expand-Update $archive $stage $meta
    foreach ($name in $script:Files) { [IO.File]::WriteAllText((Join-Path $target $name), 'old-' + $name) }
    [IO.File]::WriteAllText((Join-Path $target 'settings.json'), 'keep-user-settings')
    Apply-Update $stage $target
    Assert ((Get-FileHash -LiteralPath (Join-Path $target 'catengar.exe')).Hash -eq (Get-FileHash -LiteralPath $script:NewExe).Hash) 'Wrong installed binary'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'settings.json')) -eq 'keep-user-settings') 'Unrelated file changed'
    Restore-Update $stage $target $script:Files
    foreach ($name in $script:Files) { Assert ([IO.File]::ReadAllText((Join-Path $target $name)) -eq ('old-' + $name)) 'Restore failed' }
    Remove-Stage $stage $target
    Assert (!(Test-Path -LiteralPath $stage)) 'Stage cleanup failed'
    Reject { Remove-Stage $target $testRoot } 'InvalidStage'

    # Reject traversal, duplicate, extra and missing entries before installation.
    $malformed = @(
        ,(@('../catengar.exe') + $script:Files[1..5])
        ,(@('catengar.exe') + $script:Files[0..4])
        ,($script:Files[0..4])
        ,($script:Files + @('extra.exe'))
    )
    foreach ($names in $malformed) {
        $stage = New-Stage $target
        $archive = Join-Path $stage 'package.zip'
        $meta = Zip-Files $archive $names
        Reject { Expand-Update $archive $stage $meta } 'InvalidArchive'
        Remove-Stage $stage $target
    }

    # A sharing violation late in the transaction must restore earlier files.
    $stage = New-Stage $target
    $archive = Join-Path $stage 'package.zip'
    $meta = Zip-Files $archive $script:Files
    Expand-Update $archive $stage $meta
    $held = [IO.File]::Open((Join-Path $target 'WebView2Loader.dll'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Reject { Apply-Update $stage $target } 'InstallFailed' } finally { $held.Dispose() }
    foreach ($name in $script:Files) { Assert ([IO.File]::ReadAllText((Join-Path $target $name)) -eq ('old-' + $name)) 'Transaction rollback failed' }
    Remove-Stage $stage $target

    # Exercise the actual out-of-process handshake, parent wait and relaunch.
    [IO.File]::Copy($script:NewExe, (Join-Path $target 'catengar.exe'), $true)
    $stage = New-Stage $target
    $archive = Join-Path $stage 'package.zip'
    $meta = Zip-Files $archive $script:Files
    Expand-Update $archive $stage $meta
    $engine = Join-Path $testRoot 'engine.ps1'
    $engineSource = [IO.File]::ReadAllText((Join-Path $projectRoot 'src/updater.ps1'))
    if (Get-Process -Name 'League of Legends' -ErrorAction SilentlyContinue) {
        Reject { Assert-GameIdle } 'GameRunning'
    }
    # The real game must remain untouched. Only this isolated fixture copy skips
    # the game guard so the replacement/rollback handshake can run during a match.
    $engineSource = [regex]::Replace($engineSource, '(?s)function Assert-GameIdle \{.*?\n\}', 'function Assert-GameIdle {}')
    $engineSource = $engineSource.Replace('Get-ErrorMessage $_.Exception.ToString()', '$_.Exception.ToString()')
    [IO.File]::WriteAllText($engine, $engineSource, [Text.UTF8Encoding]::new($true))
    $parentProcess = Start-Process -FilePath (Join-Path $target 'catengar.exe') -ArgumentList '20000' -WindowStyle Hidden -PassThru
    $request = Join-Path $testRoot 'request.json'
    $receipt = Join-Path $testRoot 'receipt.json'
    Write-JsonFile $request @{ executable = (Join-Path $target 'catengar.exe'); parent = $parentProcess.Id; stage = $stage; version = '0.1.2'; receipt = $receipt }
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $engine + '" -Mode Install -Request "' + $request + '"'
    $installer = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        while (!(Test-Path -LiteralPath ($request + '.ready')) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        if (!(Test-Path -LiteralPath ($request + '.ready')) -and (Test-Path -LiteralPath ($request + '.result'))) {
            Write-Output ([IO.File]::ReadAllText($request + '.result'))
        }
        Assert (Test-Path -LiteralPath ($request + '.ready')) 'Installer did not arm'
        Assert (!(Test-Path -LiteralPath (Join-Path $stage 'backup'))) 'Installer modified files before confirmation'
        [IO.File]::WriteAllText(($request + '.commit'), 'install')
        Start-Sleep -Milliseconds 300
        Assert (!(Test-Path -LiteralPath (Join-Path $stage 'backup'))) 'Installer modified files before parent exit'
        $parentProcess.Kill(); $parentProcess.WaitForExit()
        Assert ($installer.WaitForExit(20000)) 'Installer timed out'
        $received = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
        Assert ($received.status -eq 'updated') ('Install receipt failed: ' + $received.message)
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (!(Test-Path -LiteralPath (Join-Path $target 'restarted.txt')) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Assert (Test-Path -LiteralPath (Join-Path $target 'restarted.txt')) 'App was not relaunched'
    } finally {
        if (!$parentProcess.HasExited) { $parentProcess.Kill(); $parentProcess.WaitForExit() }
        if (!$installer.HasExited) { $installer.Kill(); $installer.WaitForExit() }
        $parentProcess.Dispose(); $installer.Dispose()
    }
    Write-Output "Updater checks passed: $script:Passed"
} finally {
    # This exact, newly-created test directory must stay under the system temp directory.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -cnotmatch '^catengar-update-test-[a-f0-9]{32}$') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
