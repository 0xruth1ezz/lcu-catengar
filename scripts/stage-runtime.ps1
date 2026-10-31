param([string]$BuildDir = 'target/x86_64-pc-windows-msvc/release')
$ErrorActionPreference = 'Stop'
$metadata = & cargo metadata --locked --format-version 1 | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'Cargo metadata failed' }
$webview = @($metadata.packages | Where-Object name -eq 'webview2-com-sys')
if ($webview.Count -ne 1) { throw 'Expected exactly one locked WebView2 dependency' }
$source = Split-Path $webview[0].manifest_path -Parent
New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'x64/WebView2Loader.dll') -Destination (Join-Path $BuildDir 'WebView2Loader.dll') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../assets/WebView2-LICENSE.txt') -Destination (Join-Path $BuildDir 'WebView2-LICENSE.txt') -Force
