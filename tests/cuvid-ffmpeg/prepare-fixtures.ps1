param(
    [string]$FFmpeg = 'C:\Windows\ffmpeg.exe',
    [string]$OutputDirectory,
    [switch]$SkipHardwareReferences
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'bin_build\cuvid-ffmpeg-20261010\fixtures' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'manifest.json')) { throw 'Use a fresh directory to preserve existing fixture evidence.' }
function Write-Crlf([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, ($Text -replace '\r?\n', "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
}
function Invoke-FFmpeg([string[]]$Arguments, [string]$Log) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $FFmpeg @Arguments 2>&1 | Out-File -LiteralPath (Join-Path $OutputDirectory $Log) -Encoding utf8; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previousPreference }
    if ($code -ne 0) { throw "FFmpeg failed: $Log ($code)" }
}
$version = & $FFmpeg -version
Write-Crlf (Join-Path $OutputDirectory 'ffmpeg-version.txt') ($version -join "`n")
$fixtureSpecs = @(
    @{ name='h264-bframes'; file='h264-bframes.mkv'; bits=8; format='NV12'; pix='yuv420p'; decoder='h264_cuvid'; encode=@('-c:v','libx264','-preset','fast','-crf','18','-g','25','-bf','3','-pix_fmt','yuv420p') },
    @{ name='mpeg4-bframes'; file='mpeg4-bframes.mp4'; bits=8; format='NV12'; pix='yuv420p'; decoder='mpeg4_cuvid'; encode=@('-c:v','mpeg4','-q:v','3','-g','25','-bf','2','-pix_fmt','yuv420p') },
    @{ name='mpeg4-avi-fallback'; file='mpeg4-avi-fallback.avi'; bits=8; format='NV12'; pix='yuv420p'; fallback=$true; encode=@('-c:v','mpeg4','-q:v','3','-g','25','-bf','2','-pix_fmt','yuv420p') },
    @{ name='hevc-main10'; file='hevc-main10.mkv'; bits=10; format='P010'; pix='yuv420p10le'; decoder='hevc_cuvid'; encode=@('-c:v','libx265','-preset','fast','-x265-params','pools=2:frame-threads=2:keyint=25:min-keyint=25:bframes=3','-crf','18','-pix_fmt','yuv420p10le') },
    @{ name='hevc-44410'; file='hevc-44410.mkv'; bits=10; format='Y416'; pix='yuv444p10le'; decoder='hevc_cuvid'; encode=@('-c:v','libx265','-preset','fast','-x265-params','pools=2:frame-threads=2:keyint=25:min-keyint=25:bframes=3','-crf','18','-pix_fmt','yuv444p10le') },
    @{ name='hevc-main12'; file='hevc-main12.mkv'; bits=12; format='P016'; pix='yuv420p12le'; decoder='hevc_cuvid'; encode=@('-c:v','libx265','-preset','fast','-x265-params','pools=2:frame-threads=2:keyint=25:min-keyint=25:bframes=3','-crf','18','-pix_fmt','yuv420p12le') },
    @{ name='vp9'; file='vp9.mkv'; bits=8; format='NV12'; pix='yuv420p'; decoder='vp9_cuvid'; encode=@('-c:v','libvpx-vp9','-deadline','realtime','-cpu-used','8','-row-mt','1','-g','25','-b:v','0','-crf','24','-pix_fmt','yuv420p') },
    @{ name='av1'; file='av1.mkv'; bits=8; format='NV12'; pix='yuv420p'; decoder='av1_cuvid'; encode=@('-c:v','libaom-av1','-cpu-used','8','-row-mt','1','-threads','4','-g','25','-lag-in-frames','8','-b:v','0','-crf','24','-pix_fmt','yuv420p') },
    @{ name='h264-tff'; file='h264-tff.mkv'; bits=8; format='NV12'; pix='yuv420p'; decoder='h264_cuvid'; interlaced=$true; encode=@('-vf','tinterlace=interleave_top','-c:v','libx264','-preset','fast','-flags','+ilme+ildct','-x264-params','tff=1','-crf','18','-g','25','-bf','3','-pix_fmt','yuv420p') },
    @{ name='mpeg2-tff'; file='mpeg2-tff.mkv'; bits=8; format='NV12'; pix='yuv420p'; decoder='mpeg2_cuvid'; interlaced=$true; encode=@('-vf','tinterlace=interleave_top','-c:v','mpeg2video','-flags','+ilme+ildct','-field_order','tt','-g','12','-bf','2','-q:v','3','-pix_fmt','yuv420p') },
    @{ name='mpeg2-bff'; file='mpeg2-bff.mkv'; bits=8; format='NV12'; pix='yuv420p'; decoder='mpeg2_cuvid'; interlaced=$true; encode=@('-vf','tinterlace=interleave_bottom','-c:v','mpeg2video','-flags','+ilme+ildct','-field_order','bb','-g','12','-bf','2','-q:v','3','-pix_fmt','yuv420p') },
    @{ name='hevc-42210-fallback'; file='hevc-42210-fallback.mkv'; bits=10; format='P210'; pix='yuv422p10le'; fallback=$true; encode=@('-c:v','libx265','-preset','fast','-x265-params','pools=2:frame-threads=2:keyint=25:min-keyint=25:bframes=3','-crf','18','-pix_fmt','yuv422p10le') },
    @{ name='ffv1-fallback'; file='ffv1-fallback.mkv'; bits=8; format='NV12'; pix='yuv420p'; fallback=$true; encode=@('-c:v','ffv1','-level','3','-pix_fmt','yuv420p') }
)
$records = @()
foreach ($spec in $fixtureSpecs) {
    $inputFile = Join-Path $OutputDirectory $spec.file
    $rate = if ($spec.interlaced) { 50 } else { 25 }
    $arguments = @('-hide_banner','-loglevel','info','-f','lavfi','-i',"testsrc2=size=320x240:rate=${rate}:duration=4",'-an') + $spec.encode + @('-y',$inputFile)
    Invoke-FFmpeg $arguments "$($spec.name)-encode.log"
    $references = @{}
    $referenceModes = @('software')
    if (-not $SkipHardwareReferences -and -not $spec.fallback) {
        $referenceModes += 'weave'
        if ($spec.interlaced) { $referenceModes += 'adaptive-single','adaptive-double' }
    }
    foreach ($mode in $referenceModes) {
        $stem = "$($spec.name)-$mode"
        $decode = if ($mode -eq 'software') { @('-threads','1') }
            elseif ($mode -eq 'weave') { @('-c:v',$spec.decoder,'-deint','weave') }
            else { @('-c:v',$spec.decoder,'-deint','adaptive','-drop_second_field', $(if ($mode -eq 'adaptive-single') { '1' } else { '0' })) }
        $base = @('-hide_banner','-loglevel','info') + $decode + @('-i',$inputFile,'-map','0:v:0','-an','-fps_mode','passthrough','-pix_fmt',$spec.pix)
        $framehash = "$stem.framehash.txt"
        $md5file = "$stem.md5.txt"
        Invoke-FFmpeg ($base + @('-f','framehash','-hash','sha256','-y',(Join-Path $OutputDirectory $framehash))) "$stem-framehash.log"
        Invoke-FFmpeg ($base + @('-f','md5','-y',(Join-Path $OutputDirectory $md5file))) "$stem-md5.log"
        $frames = @(Get-Content -LiteralPath (Join-Path $OutputDirectory $framehash) | Where-Object { $_ -match '^0,' })
        $md5 = ((Get-Content -LiteralPath (Join-Path $OutputDirectory $md5file) -Raw).Trim() -split '=')[-1]
        $references[$mode] = @{ framehash=$framehash; md5=$md5; frames=$frames.Count }
    }
    $records += [pscustomobject]@{
        name=$spec.name; file=$spec.file; kind='synthetic-testsrc2'; sha256=(Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash;
        bits=$spec.bits; output_format=$spec.format; canonical_format=$spec.pix; width=320; height=240; fps=25;
        fallback=[bool]$spec.fallback; interlaced=[bool]$spec.interlaced; references=$references
    }
    Write-Output "$($spec.name): encoded, references complete"
}
# Retain one existing AVS3 fixture to verify the new selection preserves the established software decoder.
$avsSource = Join-Path $root 'bin_build\avs-first\fixtures\avs3-party-8bit.ts'
if (Test-Path -LiteralPath $avsSource) {
    $file = 'avs3-fallback.ts'
    Copy-Item -LiteralPath $avsSource -Destination (Join-Path $OutputDirectory $file)
    $stem = 'avs3-fallback-software'
    $base = @('-hide_banner','-loglevel','info','-threads','1','-i',(Join-Path $OutputDirectory $file),'-map','0:v:0','-an','-fps_mode','passthrough','-pix_fmt','yuv420p')
    Invoke-FFmpeg ($base + @('-f','framehash','-hash','sha256','-y',(Join-Path $OutputDirectory "$stem.framehash.txt"))) "$stem-framehash.log"
    Invoke-FFmpeg ($base + @('-f','md5','-y',(Join-Path $OutputDirectory "$stem.md5.txt"))) "$stem-md5.log"
    $frames = @(Get-Content -LiteralPath (Join-Path $OutputDirectory "$stem.framehash.txt") | Where-Object { $_ -match '^0,' })
    $md5 = ((Get-Content -LiteralPath (Join-Path $OutputDirectory "$stem.md5.txt") -Raw).Trim() -split '=')[-1]
    $records += [pscustomobject]@{ name='avs3-fallback'; file=$file; kind='official-AVS3-existing-fixture'; sha256=(Get-FileHash -LiteralPath (Join-Path $OutputDirectory $file)).Hash; bits=8; output_format='NV12'; canonical_format='yuv420p'; width=832; height=480; fps=50; fallback=$true; interlaced=$false; references=@{software=@{framehash="$stem.framehash.txt";md5=$md5;frames=$frames.Count}} }
}
$manifest = [pscustomobject]@{ generated_utc=[DateTime]::UtcNow.ToString('o'); ffmpeg=$FFmpeg; ffmpeg_sha256=(Get-FileHash -LiteralPath $FFmpeg).Hash; hardware_references=(-not $SkipHardwareReferences); fixtures=$records }
Write-Crlf (Join-Path $OutputDirectory 'manifest.json') ($manifest | ConvertTo-Json -Depth 12)
Get-ChildItem -LiteralPath $OutputDirectory -File | Where-Object Extension -In '.txt','.log','.json' | ForEach-Object {
    $contents=[IO.File]::ReadAllText($_.FullName)
    [IO.File]::WriteAllText($_.FullName, ($contents -replace '\r?\n', "`r`n"), [Text.UTF8Encoding]::new($false))
}
