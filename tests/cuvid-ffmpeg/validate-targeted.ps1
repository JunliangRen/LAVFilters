param(
    [Parameter(Mandatory=$true)][string]$Package,
    [ValidateSet('x64','x86')][string]$Platform='x64',
    [string]$HarnessPath,
    [string]$OutputDirectory,
    [string]$FFmpeg='C:\Windows\ffmpeg.exe'
)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $HarnessPath){$HarnessPath=Join-Path $root "bin_build\cuvid-ffmpeg-20261010\harness\$Platform\graph-regression-$Platform.exe"}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root "bin_build\cuvid-ffmpeg-20261010\targeted\$Platform"}
$Package=(Resolve-Path -LiteralPath $Package).Path
$HarnessPath=(Resolve-Path -LiteralPath $HarnessPath).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory|Out-Null
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
if(@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count){throw 'Use a fresh OutputDirectory to preserve prior evidence.'}
$failures=[Collections.Generic.List[string]]::new()
function Verify([bool]$Condition,[string]$Message){if(-not $Condition -and -not $failures.Contains($Message)){$failures.Add($Message);Write-Warning $Message}}
function Write-Crlf([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,($Text -replace '\r?\n',"`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))}
function Invoke-Logged([string]$Executable,[object[]]$Arguments,[string]$Log){
    $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{& $Executable @Arguments 2>&1|Out-File -LiteralPath (Join-Path $OutputDirectory $Log) -Encoding utf8;$code=$LASTEXITCODE}
    finally{$ErrorActionPreference=$old}
    return $code
}
function Run-Graph([string]$Id,[string]$Fixture,[int]$Backend,[string]$Mode,[string]$Expected,[string]$Live=''){
    $path=Join-Path $OutputDirectory "$Id.json"
    $arguments=@($Package,$Fixture,8,1,$path,'NV12',$Backend,$Mode,$Expected,-1,120000)
    if($Live){$arguments+=@('-',$Live)}
    $code=Invoke-Logged $HarnessPath $arguments "$Id.log"
    Verify ($code -eq 0) "Graph failed: $Id ($code)"
    if(-not(Test-Path -LiteralPath $path)){throw "Missing graph report: $Id"}
    $report=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    Verify ($report.pointer_bits -eq $(if($Platform -eq 'x64'){64}else{32})) "Process architecture differs: $Id"
    foreach($segment in $report.segments){Verify ($segment.pass -and $segment.hr -eq 0 -and $segment.event -eq 1) "EOS/status failure: $Id/$($segment.name)"}
    return $report
}
$started=[DateTime]::UtcNow.ToString('o')
$binaries=@(Get-ChildItem -LiteralPath $Package -File|Where-Object Extension -In '.dll','.ax'|Sort-Object Name|ForEach-Object{@{file=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
$harnessHash=(Get-FileHash -LiteralPath $HarnessPath).Hash
$fixtures=@()
foreach($spec in @(@{name='ntsc-mpeg2-tff';rate='60000/1001';seconds=4;interlaced=$true},@{name='live-mpeg2-tff';rate='50';seconds=8;interlaced=$true},@{name='force-progressive';rate='25';seconds=4;interlaced=$false},@{name='force-mpeg4';rate='25';seconds=4;interlaced=$false;codec='mpeg4';extension='mp4'},@{name='adaptive-mpeg4-tff';rate='50';seconds=4;interlaced=$true;codec='mpeg4';extension='mp4'})){
    $extension=if($spec.extension){$spec.extension}else{'mkv'}
    $codec=if($spec.codec){$spec.codec}else{'mpeg2video'}
    $path=Join-Path $OutputDirectory "$($spec.name).$extension"
    $arguments=@('-hide_banner','-loglevel','info','-f','lavfi','-i',"testsrc2=size=320x240:rate=$($spec.rate):duration=$($spec.seconds)",'-an')
    if($spec.interlaced){$arguments+=@('-vf','tinterlace=interleave_top','-flags','+ilme+ildct','-field_order','tt')}
    $arguments+=@('-c:v',$codec,'-g','12','-bf','2','-q:v','3','-pix_fmt','yuv420p','-y',$path)
    $code=Invoke-Logged $FFmpeg $arguments "$($spec.name)-encode.log"
    if($code -ne 0){throw "Fixture generation failed: $($spec.name) ($code)"}
    $fixtures+=@{name=$spec.name;path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash;encode_arguments=$arguments}
}
$ntsc=Run-Graph 'ntsc-adaptive-double' $fixtures[0].path 6 'adaptive-double' 'cuvid (ffmpeg)'
$fieldDuration=[long][Math]::Floor(10000000.0*1001/60000)
# Matroska stores this fixture's input PTS in milliseconds. Later fields derive
# their offset from those rounded packet PTS; permit at most one millisecond of
# cadence jitter rather than requiring perfectly abutting sample intervals.
$packetQuantization=10000L
$ntscSegments=@()
Verify ($ntsc.segments.Count -eq 5) 'NTSC decode/seek coverage is incomplete'
foreach($segment in $ntsc.segments){
    $frames=@($segment.frame_data)
    Verify ($segment.decoder -eq 'cuvid (ffmpeg)' -and $segment.active_device) "NTSC backend differs: $($segment.name)"
    Verify ($frames.Count -gt 2) "NTSC segment is too short: $($segment.name)"
    $largestError=0L;$largestOverlap=0L
    for($i=0;$i -lt $frames.Count;++$i){
        Verify ($frames[$i].avg_duration -eq $fieldDuration -and $frames[$i].stop-$frames[$i].start -eq $fieldDuration) "NTSC output field duration differs: $($segment.name)"
        Verify (($frames[$i].flags -band 8) -eq 8 -and $frames[$i].media_interlace_flags -eq 0) "NTSC output is not progressive: $($segment.name)"
        if($i){
            $cadenceError=[Math]::Abs(($frames[$i].start-$frames[$i-1].start)-$fieldDuration)
            $overlap=$frames[$i-1].stop-$frames[$i].start
            $largestError=[Math]::Max($largestError,$cadenceError);$largestOverlap=[Math]::Max($largestOverlap,$overlap)
        }
    }
    Verify ($largestError -le $packetQuantization) "NTSC field cadence exceeds packet timestamp quantization: $($segment.name) ($largestError ticks)"
    Verify ($largestOverlap -le $packetQuantization) "NTSC field intervals overlap beyond packet timestamp quantization: $($segment.name) ($largestOverlap ticks)"
    if($segment.name -in 'whole-file','whole-replay'){
        Verify ($frames[0].start -eq 0 -and $frames[1].start-$frames[0].start -eq $fieldDuration) "NTSC first second-field timestamp differs: $($segment.name)"
    }
    $ntscSegments+=@{name=$segment.name;frames=$frames.Count;first_start=$frames[0].start;second_start=$frames[1].start;largest_cadence_error=$largestError;largest_overlap=$largestOverlap}
}
$liveRecords=@()
$source=Run-Graph 'source-weave' $fixtures[1].path 6 'disable' 'cuvid (ffmpeg)'
$sourceFrames=@($source.segments[0].frame_data)
Verify ($sourceFrames.Count -eq 200) 'Live source control does not retain all encoded display pictures'
$staticControls=@{}
foreach($mode in 'adaptive-double','disable','adaptive-single','adaptive-force','adaptive-tff','adaptive-bff'){
    $staticControls[$mode]=Run-Graph "static-$mode" $fixtures[1].path 6 $mode 'cuvid (ffmpeg)'
}
$standalonePath=Join-Path $OutputDirectory 'live-interlaced-adaptive.oracle.framehash.txt'
$standaloneArguments=@('-hide_banner','-loglevel','warning','-c:v','mpeg2_cuvid','-deint','adaptive','-drop_second_field','1','-i',$fixtures[1].path,'-an','-fps_mode','passthrough','-pix_fmt','yuv420p','-f','framehash','-hash','sha256','-y',$standalonePath)
Verify ((Invoke-Logged $FFmpeg $standaloneArguments 'live-interlaced-adaptive.oracle.log') -eq 0) 'Independent standalone interlaced adaptive oracle failed'
$standaloneHashes=@(Get-Content -LiteralPath $standalonePath|Where-Object{$_ -match '^0,'}|ForEach-Object{($_ -split ',')[-1].Trim()})
foreach($mode in 'adaptive-single','adaptive-force','adaptive-tff'){
    $frames=@($staticControls[$mode].segments[0].frame_data)
    Verify ($frames.Count -eq $standaloneHashes.Count -and (@($frames|ForEach-Object sha256)-join ',') -eq ($standaloneHashes-join ',')) "Interlaced static GPU pixels differ from standalone adaptive oracle: $mode"
}
Verify ((@($staticControls['adaptive-bff'].segments[0].frame_data|ForEach-Object sha256)-join ',') -ne (@($staticControls['adaptive-tff'].segments[0].frame_data|ForEach-Object sha256)-join ',')) 'Explicit BFF does not change the TFF GPU field selection'
foreach($scenario in 'cycle','force','tff','bff'){
    $report=Run-Graph "live-$scenario" $fixtures[1].path 6 'adaptive-double' 'cuvid (ffmpeg)' $scenario
    Verify ($report.live_scenario -eq $scenario -and $report.active_device) "Live gate scenario or initial GPU differs: $scenario"
    Verify ($report.segments.Count -eq 1) "Live graph was stopped/replayed: $scenario"
    $segment=$report.segments[0]
    # Inspect every display picture, including the boundaries of all changes.
    # Each source picture contributes one frame or two adjacent fields; a fresh
    # decoder at an MPEG2 open GOP would omit leading B pictures and fail here.
    $displayGroups=@{}
    foreach($frame in $segment.frame_data){
        Verify ($frame.start -ge 0 -and $frame.start%200000L -eq 0) "Live output leaves the source field timeline: $scenario"
        $origin=$frame.start-$frame.start%400000L
        $key=[string]$origin
        if(-not $displayGroups.ContainsKey($key)){$displayGroups[$key]=[Collections.Generic.List[object]]::new()}
        $displayGroups[$key].Add($frame)
    }
    Verify ($displayGroups.Count -eq $sourceFrames.Count) "Live transition loses or duplicates encoded display positions: $scenario"
    foreach($original in $sourceFrames){
        $group=@($displayGroups[[string]$original.start])
        Verify ($group.Count -in 1,2) "Live transition loses a source display picture: $scenario/$($original.start)"
        if(-not $group.Count){continue}
        $duration=if($group.Count -eq 2){200000L}else{400000L}
        for($i=0;$i -lt $group.Count;++$i){
            Verify ($group[$i].start -eq $original.start+$i*$duration) "Live transition duplicates or skips a field: $scenario/$($original.start)"
            Verify ($group[$i].avg_duration -eq $duration -and $group[$i].stop-$group[$i].start -eq $duration) "Live transition retains stale timing for a queued picture: $scenario/$($original.start)"
        }
    }
    $phases=@()
    foreach($phase in 0..3){
        $all=@($segment.frame_data|Where-Object phase -EQ $phase)
        # The whole timeline above checks transition coverage. Compare stable
        # pixels separately, after the adaptive GPU's short history has settled.
        Verify ($all.Count -ge 16) "Live phase did not continue decoding: $scenario/$phase"
        $stable=@($all|Select-Object -Last 12)
        $expectedDecoder='cuvid (ffmpeg)'
        $expectedDuration=if($phase -eq 0 -or ($phase -eq 3 -and $scenario -eq 'cycle')){200000L}else{400000L}
        $progressive=$phase -ne 1
        $mode=if($phase -eq 0 -or ($phase -eq 3 -and $scenario -eq 'cycle')){'adaptive-double'}elseif($phase -eq 1){'disable'}elseif($phase -eq 2){'adaptive-single'}else{"adaptive-$scenario"}
        $static=@{}
        foreach($frame in $staticControls[$mode].segments[0].frame_data){$static[[string]$frame.start]=$frame}
        for($i=0;$i -lt $stable.Count;++$i){
            $frame=$stable[$i]
            Verify ($frame.decoder -eq $expectedDecoder) "Live setting leaves stale backend: $scenario/$phase ($($frame.decoder) versus $expectedDecoder)"
            Verify ($frame.avg_duration -eq $expectedDuration -and $frame.stop-$frame.start -eq $expectedDuration) "Live setting leaves stale output rate: $scenario/$phase ($($frame.avg_duration) versus $expectedDuration)"
            if($i){Verify ($frame.start-$stable[$i-1].start -eq $expectedDuration) "Live setting leaves stale sample cadence: $scenario/$phase"}
            $control=$static[[string]$frame.start]
            Verify ([bool]$control -and $frame.sha256 -eq $control.sha256 -and $frame.flags -eq $control.flags) "Live output differs from independently started static GPU control: $scenario/$phase"
            $mediaMatches=$frame.media_interlace_flags -eq $control.media_interlace_flags
            if(-not $mediaMatches -and $control.media_interlace_flags -eq 0 -and ($frame.media_interlace_flags -band 1)){
                # LAV intentionally keeps an advertised interlaced media type
                # for renderers that can drop frames when it is cleared. An
                # earlier queued weave sample must have advertised that type;
                # current processed samples still need the progressive flag.
                $mediaMatches=@($segment.frame_data|Where-Object{$_.start -le $frame.start -and ($_.media_interlace_flags -band 1) -and ($_.flags -band 8) -eq 0}).Count -gt 0
            }
            Verify $mediaMatches "Live media flags differ from LAV's retained-interlace policy: $scenario/$phase"
            if($progressive){Verify (($frame.flags -band 8) -eq 8) "Live adaptive output sample flags differ: $scenario/$phase"}
            else{Verify (($frame.flags -band 8) -eq 8) "Live Disabled does not suppress renderer deinterlacing: $scenario/$phase"}
        }
        $phases+=@{phase=$phase;frames=$all.Count;expected_decoder=$expectedDecoder;expected_duration=$expectedDuration;actual_decoders=@($stable|ForEach-Object decoder|Select-Object -Unique);actual_durations=@($stable|ForEach-Object avg_duration|Select-Object -Unique);actual_flags=@($stable|ForEach-Object flags|Select-Object -Unique);actual_media_flags=@($stable|ForEach-Object media_interlace_flags|Select-Object -Unique)}
    }
    $liveRecords+=@{scenario=$scenario;source_display_pictures=$sourceFrames.Count;retained_display_positions=$displayGroups.Count;phases=$phases}
}
$force=Run-Graph 'force-progressive-new' $fixtures[2].path 6 'adaptive-force' 'cuvid (ffmpeg)'
$forceAuto=Run-Graph 'force-progressive-auto' $fixtures[2].path 6 'adaptive-single' 'cuvid (ffmpeg)'
$forceNewFrames=@($force.segments[0].frame_data)
Verify ($forceNewFrames.Count -eq 100) 'Force progressive fixture loses or duplicates pictures'
Verify ($forceAuto.segments[0].frames -eq 100) 'Automatic progressive control changes source frame coverage'
foreach($frame in $forceNewFrames){
    Verify ($frame.avg_duration -eq 400000L -and $frame.stop-$frame.start -eq 400000L) 'Forced progressive single output rate differs'
    Verify ($frame.flags -band 8 -and $frame.media_interlace_flags -eq 0) 'Forced GPU output is not flagged progressive'
}
$forceDouble=Run-Graph 'force-progressive-double' $fixtures[2].path 6 'adaptive-force-double' 'cuvid (ffmpeg)'
foreach($segment in $forceDouble.segments|Where-Object name -In 'whole-file','whole-replay'){
    Verify ($segment.frames -eq 200) "Force on a progressive source does not emit both fields: $($segment.name)"
    foreach($frame in $segment.frame_data){
        Verify ($frame.avg_duration -eq 200000L -and $frame.stop-$frame.start -eq 200000L) "Forced progressive double rate differs: $($segment.name)"
        Verify ($frame.flags -band 8 -and $frame.media_interlace_flags -eq 0) "Forced progressive double output flags differ: $($segment.name)"
    }
}
$mpeg4Force=Run-Graph 'force-mpeg4-double' $fixtures[3].path 6 'adaptive-force-double' 'cuvid (ffmpeg)'
foreach($segment in $mpeg4Force.segments){
    $frames=@($segment.frame_data)
    Verify ($segment.decoder -eq 'cuvid (ffmpeg)' -and $segment.active_device) "MPEG4 forced double does not run on GPU: $($segment.name)"
    if($segment.name -in 'whole-file','whole-replay'){
        Verify ($frames.Count -eq 200 -and $frames[0].start -eq 0) "MPEG4 forced double picture coverage differs: $($segment.name)"
        for($i=0;$i -lt $frames.Count;++$i){
            Verify ($frames[$i].avg_duration -eq 200000L -and $frames[$i].stop-$frames[$i].start -eq 200000L) "MPEG4 forced double uses stale source frame duration: $($segment.name)"
            if($i){Verify ($frames[$i].start-$frames[$i-1].start -eq 200000L) "MPEG4 forced double field cadence differs: $($segment.name)"}
        }
    }
}
$mpeg4Adaptive=Run-Graph 'adaptive-mpeg4-double' $fixtures[4].path 6 'adaptive-double' 'cuvid (ffmpeg)'
foreach($segment in $mpeg4Adaptive.segments){
    $frames=@($segment.frame_data)
    Verify ($segment.decoder -eq 'cuvid (ffmpeg)' -and $segment.active_device) "MPEG4 adaptive double does not run on GPU: $($segment.name)"
    if($segment.name -in 'whole-file','whole-replay'){
        Verify ($frames.Count -eq 200 -and $frames[0].start -eq 0) "MPEG4 adaptive double picture coverage differs: $($segment.name)"
    }
    for($i=0;$i -lt $frames.Count;++$i){
        Verify ($frames[$i].avg_duration -eq 200000L -and $frames[$i].stop-$frames[$i].start -eq 200000L) "MPEG4 adaptive double uses stale source frame duration: $($segment.name)"
        if($i){Verify ($frames[$i].start-$frames[$i-1].start -eq 200000L) "MPEG4 adaptive double field cadence differs: $($segment.name)"}
    }
}
foreach($binary in $binaries){Verify ((Get-FileHash -LiteralPath (Join-Path $Package $binary.file)).Hash -eq $binary.sha256) "Candidate changed: $($binary.file)"}
foreach($fixture in $fixtures){Verify ((Get-FileHash -LiteralPath $fixture.path).Hash -eq $fixture.sha256) "Fixture changed: $($fixture.name)"}
Verify ((Get-FileHash -LiteralPath $HarnessPath).Hash -eq $harnessHash) 'Harness changed during testing'
Write-Crlf $standalonePath ([IO.File]::ReadAllText($standalonePath).TrimEnd())
$summary=[ordered]@{scope='Targeted GPU/DirectShow NTSC first-field timing and continuous live settings; every source display position retained; separate static GPU controls and standalone adaptive reference for interlaced Auto/Force/TFF; BFF pixels use static control plus distinct field selection; progressive Force validates coverage/cadence/flags without an independent forced-pixel oracle; retained interlaced media flags follow existing LAV renderer policy';platform=$Platform;package=$Package;harness=$HarnessPath;harness_sha256=$harnessHash;candidate_binary_sha256=$binaries;ffmpeg=$FFmpeg;ffmpeg_sha256=(Get-FileHash -LiteralPath $FFmpeg).Hash;started_utc=$started;completed_utc=[DateTime]::UtcNow.ToString('o');fixtures=$fixtures;ntsc_segments=$ntscSegments;live_settings=$liveRecords;interlaced_gpu_oracle=@{framehash=$standalonePath;sha256=(Get-FileHash -LiteralPath $standalonePath).Hash;frames=$standaloneHashes.Count;arguments=$standaloneArguments};force_progressive=@{frames=$forceNewFrames.Count;double_frames=$forceDouble.segments[0].frames};passed=($failures.Count -eq 0);failures=@($failures)}
Write-Crlf (Join-Path $OutputDirectory 'validation.json') ($summary|ConvertTo-Json -Depth 12)
if(-not $summary.passed){throw "$($failures.Count) targeted regressions failed; see validation.json"}
Write-Output 'NTSC timing and continuous live settings regressions passed.'
