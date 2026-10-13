param(
    [Parameter(Mandatory=$true)][string]$Package,
    [ValidateSet('x64','x86')][string]$Platform='x64',
    [string]$FixtureDirectory,
    [string]$HarnessPath,
    [string]$OutputDirectory,
    [string]$FFmpeg='C:\Windows\ffmpeg.exe'
)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $FixtureDirectory) { $FixtureDirectory=Join-Path $root 'bin_build\cuvid-ffmpeg-20261010\fixtures' }
if (-not $HarnessPath) { $HarnessPath=Join-Path $root "bin_build\cuvid-ffmpeg-20261010\harness\$Platform\graph-regression-$Platform.exe" }
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $root "bin_build\cuvid-ffmpeg-20261010\adaptive-oracle\$Platform" }
$Package=(Resolve-Path -LiteralPath $Package).Path
$FixtureDirectory=(Resolve-Path -LiteralPath $FixtureDirectory).Path
$HarnessPath=(Resolve-Path -LiteralPath $HarnessPath).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'validation.json')) { throw 'Use a fresh directory to preserve prior oracle evidence.' }
function Write-Crlf([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,($Text -replace '\r?\n',"`r`n")+"`r`n",[Text.UTF8Encoding]::new($false)) }
$failures=[Collections.Generic.List[string]]::new()
function Verify([bool]$Condition,[string]$Message) { if (-not $Condition -and -not $failures.Contains($Message)) { $failures.Add($Message);Write-Warning $Message } }
function Invoke-Logged([string]$Executable,[object[]]$Arguments,[string]$Log) {
    $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try { & $Executable @Arguments 2>&1 | Out-File -LiteralPath $Log -Encoding utf8;$code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$old }
    Verify ($code -eq 0) "Command failed: $Log ($code)"
}
function Sequence($Segment,[string]$Property) { return (@($Segment.frame_data | ForEach-Object $Property) -join ',') }
$started=[DateTime]::UtcNow.ToString('o')
$binaries=@(Get-ChildItem -LiteralPath $Package -File | Where-Object Extension -In '.dll','.ax' | Sort-Object Name | ForEach-Object { @{file=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash} })
$harnessHash=(Get-FileHash -LiteralPath $HarnessPath).Hash
$manifestPath=Join-Path $FixtureDirectory 'manifest.json'
$manifestHash=(Get-FileHash -LiteralPath $manifestPath).Hash
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$records=@()
foreach ($fixture in $manifest.fixtures | Where-Object interlaced) {
    foreach ($mode in 'adaptive-single','adaptive-double') {
        $id="$($fixture.name)-$mode"
        $work=Join-Path $OutputDirectory $id
        $packets=Join-Path $work 'packets'
        New-Item -ItemType Directory -Force -Path $packets | Out-Null
        $directPath=Join-Path $work 'direct.json';$tracedPath=Join-Path $work 'traced.json'
        $inputFile=Join-Path $FixtureDirectory $fixture.file
        Verify ((Get-FileHash -LiteralPath $inputFile).Hash -eq $fixture.sha256) "Fixture changed: $id"
        $common=@($Package,$inputFile,$fixture.bits,1,$directPath,$fixture.output_format,6,$mode,'cuvid (ffmpeg)',-1,120000)
        Invoke-Logged $HarnessPath $common (Join-Path $work 'direct.log')
        $common[4]=$tracedPath
        Invoke-Logged $HarnessPath ($common+@($packets)) (Join-Path $work 'traced.log')
        if (-not (Test-Path -LiteralPath $directPath) -or -not (Test-Path -LiteralPath $tracedPath)) { continue }
        $direct=Get-Content -LiteralPath $directPath -Raw | ConvertFrom-Json
        $traced=Get-Content -LiteralPath $tracedPath -Raw | ConvertFrom-Json
        Verify ($direct.segments.Count -eq 5 -and $traced.segments.Count -eq 5) "Missing trace controls: $id"
        $expectedDuration=[long](10000000/$fixture.fps/$(if($mode -eq 'adaptive-double'){2}else{1}))
        $segments=@()
        foreach ($segment in $direct.segments) {
            $control=$traced.segments | Where-Object name -EQ $segment.name
            $traceEqual=$segment.frames -eq $control.frames
            foreach ($property in 'sha256','start','stop','avg_duration','flags','media_interlace_flags') {
                $traceEqual=$traceEqual -and (Sequence $segment $property) -eq (Sequence $control $property)
            }
            Verify $traceEqual "Packet tracer changes pixels/timing/flags: $id/$($segment.name)"
            Verify ($segment.pass -and $control.pass -and $segment.decoder -eq 'cuvid (ffmpeg)' -and $control.decoder -eq 'cuvid (ffmpeg)') "Trace controls do not use running CUVID: $id/$($segment.name)"
            $packetPath=Join-Path $packets "$($segment.name).packets.json"
            $esPath=Join-Path $packets "$($segment.name).es"
            $packetReport=Get-Content -LiteralPath $packetPath -Raw | ConvertFrom-Json
            $minimum=[long]($packetReport.packets | Measure-Object -Property start -Minimum).Minimum
            $origin=[long]$packetReport.packets[0].start
            Verify ($packetReport.packets[0].key) "Exact packet history does not begin with a key picture: $id/$($segment.name)"
            # Fixed-rate fixtures allow exact display-time alignment from the
            # first decodable key picture. MPEG2 open GOPs may also contain B
            # pictures with earlier PTS that lack their preceding reference;
            # CUVID drops these rather than starting its display timeline there.
            # No mismatch-driven trimming is used.
            Verify ($origin -le 0 -and (-$origin)%$expectedDuration -eq 0) "Nonintegral packet preroll alignment: $id/$($segment.name)"
            $skip=[int](-$origin/$expectedDuration)
            $format=if($fixture.name -like 'h264-*'){'h264'}else{'mpegvideo'}
            $decoder=if($format -eq 'h264'){'h264_cuvid'}else{'mpeg2_cuvid'}
            $framehash=Join-Path $work "$($segment.name).oracle.framehash.txt"
            $arguments=@('-hide_banner','-loglevel','warning','-r',"$($fixture.fps)",'-c:v',$decoder,'-deint','adaptive','-drop_second_field',$(if($mode -eq 'adaptive-single'){'1'}else{'0'}),'-f',$format,'-i',$esPath,'-an','-fps_mode','passthrough','-pix_fmt',$fixture.canonical_format,'-f','framehash','-hash','sha256','-y',$framehash)
            Invoke-Logged $FFmpeg $arguments (Join-Path $work "$($segment.name).oracle.log")
            $lines=Get-Content -LiteralPath $framehash
            $allHashes=@($lines | Where-Object { $_ -match '^0,' } | ForEach-Object { ($_ -split ',')[-1].Trim() })
            $aligned=@($allHashes | Select-Object -Skip $skip)
            $pixelsEqual=$aligned.Count -eq $segment.frames -and ($aligned -join ',') -eq (Sequence $segment 'sha256')
            Verify $pixelsEqual "Independent exact-packet CUVID pixels differ: $id/$($segment.name) ($($aligned.Count) versus $($segment.frames))"
            $segments += [pscustomobject]@{
                name=$segment.name;packet_count=$packetReport.packets.Count;first_packet=$packetReport.packets[0];last_packet=$packetReport.packets[-1];minimum_packet_pts=$minimum;decode_origin_pts=$origin;leading_open_gop_packets=@($packetReport.packets | Where-Object {$_.start -lt $origin}).Count;discarded_negative_preroll_frames=$skip
                elementary_stream=$esPath;elementary_sha256=(Get-FileHash -LiteralPath $esPath).Hash;packet_manifest=$packetPath;packet_manifest_sha256=(Get-FileHash -LiteralPath $packetPath).Hash
                framehash=$framehash;raw_reference_frames=$allHashes.Count;aligned_hashes=$aligned;reference_frames=$aligned.Count;tracer_unchanged=$traceEqual;pixels_equal=$pixelsEqual;passed=($traceEqual -and $pixelsEqual)
            }
        }
        $records += [pscustomobject]@{id=$id;fixture=$fixture.name;source_sha256=$fixture.sha256;mode=$mode;direct_report=$directPath;traced_report=$tracedPath;segments=$segments;passed=(@($segments | Where-Object { -not $_.passed }).Count -eq 0 -and $segments.Count -eq 5)}
        Write-Output "$id`: exact compressed packet history checked for $($segments.Count) segments"
    }
}
foreach($binary in $binaries){Verify ((Get-FileHash -LiteralPath (Join-Path $Package $binary.file)).Hash -eq $binary.sha256) "Candidate changed: $($binary.file)"}
Verify ((Get-FileHash -LiteralPath $HarnessPath).Hash -eq $harnessHash) 'Harness changed during oracle testing'
$summary=[pscustomobject]@{scope='Independent standalone CUVID decoding of exact DirectShow-consumed compressed packet history; trace controls require unchanged pixels, timestamps, media timing and flags; preroll trimming derived solely from logged source PTS';platform=$Platform;started_utc=$started;completed_utc=[DateTime]::UtcNow.ToString('o');package=$Package;candidate_binary_sha256=$binaries;harness=$HarnessPath;harness_sha256=$harnessHash;fixture_manifest_sha256=$manifestHash;ffmpeg=$FFmpeg;ffmpeg_sha256=(Get-FileHash -LiteralPath $FFmpeg).Hash;graph_runs=$records.Count*2;segment_runs=@($records|ForEach-Object {$_.segments}).Count;passed=($failures.Count -eq 0 -and $records.Count -eq 6);failures=@($failures);records=$records}
Get-ChildItem -LiteralPath $OutputDirectory -Recurse -File | Where-Object Extension -In '.txt','.log','.json' | ForEach-Object { $text=[IO.File]::ReadAllText($_.FullName);[IO.File]::WriteAllText($_.FullName,($text -replace '\r?\n',"`r`n"),[Text.UTF8Encoding]::new($false)) }
Write-Crlf (Join-Path $OutputDirectory 'validation.json') ($summary | ConvertTo-Json -Depth 15)
if(-not $summary.passed){throw "$($failures.Count) adaptive oracle failures; see validation.json"}
Write-Output "$($summary.graph_runs) direct/traced graphs, $($summary.segment_runs) exact-history GPU oracle segments passed."
