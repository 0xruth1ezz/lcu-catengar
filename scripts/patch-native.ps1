$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../.tools/native/src/runtime/canvas_images.zig'
$source = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
$marker = '// catengar: cache immutable image fingerprints at registration (v1).'
if ($source.Contains($marker)) { return }

function Replace-Once([string]$old, [string]$replacement) {
    if (!$script:source.Contains($old)) { throw 'Pinned Native image patch no longer matches; review the SDK before building.' }
    $script:source = $script:source.Replace($old, $replacement)
}
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
