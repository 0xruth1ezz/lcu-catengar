$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../.tools/native/src/runtime/canvas_images.zig'
$source = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
$marker = '// catengar: cache immutable image fingerprints at registration (v1).'

function Replace-Once([string]$old, [string]$replacement) {
    if (!$script:source.Contains($old)) { throw 'Pinned Native patch no longer matches; review the SDK before building.' }
    $script:source = $script:source.Replace($old, $replacement)
}
if (!$source.Contains($marker)) {
    Replace-Once '    byte_len: usize = 0,' @'
    byte_len: usize = 0,
    // catengar: cache immutable image fingerprints at registration (v1).
    content_fingerprint: u64 = 0,
'@
    Replace-Once '                .byte_len = byte_len,' @'
                .byte_len = byte_len,
                .content_fingerprint = @max(1, std.hash.Wyhash.hash(0, rgba8)),
'@
    Replace-Once '                    .pixels = self.canvas_image_pixels[index][0..entry.byte_len],' @'
                    .pixels = self.canvas_image_pixels[index][0..entry.byte_len],
                    .content_fingerprint = entry.content_fingerprint,
'@
    [IO.File]::WriteAllText($path, $source, [Text.UTF8Encoding]::new($false))
    Write-Output 'Applied Native image fingerprint cache patch.'
}

# The pinned host forwards GPU child hit tests only for hidden_inset windows.
# Chromeless headers need the same handoff, without any system caption buttons.
$path = Join-Path $PSScriptRoot '../.tools/native/src/platform/windows/webview2_host.cpp'
$source = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
$marker = '// catengar: forward chromeless canvas drag regions to the host (v1).'
if (!$source.Contains($marker)) {
    Replace-Once 'if (found != host->windows.end() && found->second.hwnd && windowUsesHiddenTitlebar(found->second)) chrome_window = &found->second;' @'
// catengar: forward chromeless canvas drag regions to the host (v1).
                if (found != host->windows.end() && found->second.hwnd && (windowUsesHiddenTitlebar(found->second) || windowIsChromeless(found->second))) chrome_window = &found->second;
'@
    Replace-Once 'if (chrome_window->resizable && !IsZoomed(chrome_window->hwnd) && point.y >= 0 && point.y < hiddenFrameTopThickness(chrome_window->hwnd)) return HTTRANSPARENT;' 'if (windowUsesHiddenTitlebar(*chrome_window) && chrome_window->resizable && !IsZoomed(chrome_window->hwnd) && point.y >= 0 && point.y < hiddenFrameTopThickness(chrome_window->hwnd)) return HTTRANSPARENT;'
    Replace-Once 'if (captionButtonsClientRect(chrome_window->hwnd, &cluster) && PtInRect(&cluster, point)) return HTTRANSPARENT;' 'if (windowUsesHiddenTitlebar(*chrome_window) && captionButtonsClientRect(chrome_window->hwnd, &cluster) && PtInRect(&cluster, point)) return HTTRANSPARENT;'
    [IO.File]::WriteAllText($path, $source, [Text.UTF8Encoding]::new($false))
    Write-Output 'Applied Native chromeless drag-region patch.'
}
