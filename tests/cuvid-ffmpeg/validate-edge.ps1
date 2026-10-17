param(
    [Parameter(Mandatory=$true)][string]$Package,
    [ValidateSet('x64','x86')][string]$Platform='x64',
    [string]$HarnessPath,
    [string]$ProbePath,
    [string]$OutputDirectory,
    [string]$FFmpeg='C:\Windows\ffmpeg.exe',
    [string]$Python='python'
)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $HarnessPath){$HarnessPath=Join-Path $root "bin_build\cuvid-ffmpeg-20261011\harness\$Platform\graph-regression-$Platform.exe"}
if(-not $ProbePath){$ProbePath=Join-Path (Split-Path $HarnessPath -Parent) "codec-edge-probe-$Platform.exe"}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root "bin_build\cuvid-ffmpeg-20261011\edge\$Platform"}
$Package=(Resolve-Path -LiteralPath $Package).Path
$HarnessPath=(Resolve-Path -LiteralPath $HarnessPath).Path
$ProbePath=(Resolve-Path -LiteralPath $ProbePath).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory|Out-Null
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
if(@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count){throw 'Use a fresh OutputDirectory to preserve prior evidence.'}
$failures=[Collections.Generic.List[string]]::new()
$graphRecords=[Collections.Generic.List[object]]::new()
function Verify([bool]$Condition,[string]$Message){if(-not $Condition -and -not $failures.Contains($Message)){$failures.Add($Message);Write-Warning $Message}}
function Write-Crlf([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,($Text -replace '\r?\n',"`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))}
function Invoke-Logged([string]$Executable,[object[]]$Arguments,[string]$Log){
    $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{& $Executable @Arguments 2>&1|Out-File -LiteralPath (Join-Path $OutputDirectory $Log) -Encoding utf8;$code=$LASTEXITCODE}
    finally{$ErrorActionPreference=$previous}
    return $code
}
function Run-Graph([string]$Id,[string]$Fixture,[string]$Mode,[string]$Live=''){
    $path=Join-Path $OutputDirectory "$Id.json"
    $arguments=@($Package,$Fixture,8,1,$path,'NV12',6,$Mode,'cuvid (ffmpeg)',-1,120000)
    if($Live){$arguments+=@('-',$Live)}
    $code=Invoke-Logged $HarnessPath $arguments "$Id.log"
    Verify ($code -eq 0) "Graph failed: $Id ($code)"
    if(-not(Test-Path -LiteralPath $path)){throw "Missing graph report: $Id"}
    $report=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    Verify ($report.pointer_bits -eq $(if($Platform -eq 'x64'){64}else{32})) "Process architecture differs: $Id"
    foreach($segment in $report.segments){
        Verify ($segment.pass -and $segment.hr -eq 0 -and $segment.event -eq 1) "EOS/status failure: $Id/$($segment.name)"
        Verify ($segment.decoder -eq 'cuvid (ffmpeg)' -and $segment.active_device) "GPU fallback: $Id/$($segment.name)"
        foreach($frame in $segment.frame_data){Verify ($frame.decoder -eq 'cuvid (ffmpeg)') "Per-frame GPU fallback: $Id/$($segment.name)"}
    }
    $graphRecords.Add(@{id=$Id;path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash;segments=$report.segments.Count})
    return $report
}
function Run-Probe([string]$Id,[string]$Fixture,[string]$Mode){
    $path=Join-Path $OutputDirectory "$Id.json"
    $oldPath=$env:PATH
    try{$env:PATH=$Package+';'+$oldPath;$code=Invoke-Logged $ProbePath @($Fixture,$path,$Mode) "$Id.log"}
    finally{$env:PATH=$oldPath}
    Verify ($code -eq 0) "Codec probe failed: $Id ($code)"
    if(-not(Test-Path -LiteralPath $path)){throw "Missing codec report: $Id"}
    $report=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    Verify ($report.pointer_bits -eq $(if($Platform -eq 'x64'){64}else{32})) "Probe architecture differs: $Id"
    Verify ($null -ne $report.loaded_modules -and @($report.loaded_modules.PSObject.Properties).Count -eq 3) "Probe lacks loaded-DLL provenance: $Id"
    foreach($module in $report.loaded_modules.PSObject.Properties){Verify ($module.Value -eq (Join-Path $Package $module.Name)) "Probe loaded foreign DLL: $Id/$($module.Name)"}
    return $report
}
function Oracle-Hashes([string]$Id,[string]$Fixture,[object[]]$Options,[string]$Deint='weave'){
    $path=Join-Path $OutputDirectory "$Id.framehash.txt"
    $arguments=@('-hide_banner','-loglevel','warning','-c:v','mpeg2_cuvid','-deint',$Deint)
    if($Deint -eq 'adaptive'){$arguments+=@('-drop_second_field','1')}
    $arguments+=@('-i',$Fixture,'-an')+$Options+@('-fps_mode','passthrough','-pix_fmt','yuv420p','-f','framehash','-hash','sha256','-y',$path)
    Verify ((Invoke-Logged $FFmpeg $arguments "$Id.log") -eq 0) "Standalone oracle failed: $Id"
    Write-Crlf $path ([IO.File]::ReadAllText($path).TrimEnd())
    return @(Get-Content -LiteralPath $path|Where-Object{$_ -match '^0,'}|ForEach-Object{($_ -split ',')[-1].Trim()})
}
$started=[DateTime]::UtcNow.ToString('o')
$binaries=@(Get-ChildItem -LiteralPath $Package -File|Where-Object Extension -In '.dll','.ax'|Sort-Object Name|ForEach-Object{@{file=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
$harnessHash=(Get-FileHash -LiteralPath $HarnessPath).Hash
$probeHash=(Get-FileHash -LiteralPath $ProbePath).Hash
$sources=@('graph-regression.cpp','codec-edge-probe.cpp','prepare-edge-fixtures.py','validate-edge.ps1')|ForEach-Object{@{file=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash}}
$fixtures=@()
foreach($spec in @(@{name='h264-timed';rate='50';seconds=4;codec='libx264';extension='mp4';interlaced=$true;gop=25},@{name='mpeg2-progressive';rate='25';seconds=4;codec='mpeg2video';extension='m2v';interlaced=$false;gop=12},@{name='live-mpeg2-tff';rate='50';seconds=8;codec='mpeg2video';extension='mkv';interlaced=$true;gop=12})){
    $path=Join-Path $OutputDirectory "$($spec.name).$($spec.extension)"
    $arguments=@('-hide_banner','-loglevel','warning','-f','lavfi','-i',"testsrc2=size=320x240:rate=$($spec.rate):duration=$($spec.seconds)",'-an')
    if($spec.interlaced){$arguments+=@('-vf','tinterlace=interleave_top','-flags','+ilme+ildct','-field_order','tt')}
    $arguments+=@('-c:v',$spec.codec,'-g',$spec.gop,'-bf',$(if($spec.name -eq 'mpeg2-progressive'){0}else{2}),'-pix_fmt','yuv420p')
    if($spec.codec -eq 'libx264'){$arguments+=@('-x264-params','tff=1:pic-struct=0')}else{$arguments+=@('-q:v','3')}
    if($spec.extension -eq 'm2v'){$arguments+=@('-f','mpeg2video')}
    $arguments+=@('-y',$path)
    if((Invoke-Logged $FFmpeg $arguments "$($spec.name)-encode.log") -ne 0){throw "Fixture generation failed: $($spec.name)"}
    $fixtures+=@{name=$spec.name;path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash;encode_arguments=$arguments}
}
$noTiming=Join-Path $OutputDirectory 'h264-no-timing.mp4'
$noTimingMetadata=Join-Path $OutputDirectory 'h264-no-timing-metadata.json'
if((Invoke-Logged $Python @((Join-Path $PSScriptRoot 'prepare-edge-fixtures.py'),'h264-mp4-no-timing',$fixtures[0].path,$noTiming,$noTimingMetadata) 'h264-remove-timing.log') -ne 0){throw 'H264 SPS mutation failed'}
$softES=Join-Path $OutputDirectory 'soft-telecine.m2v'
$soft=Join-Path $OutputDirectory 'soft-telecine.mkv'
$softMetadata=Join-Path $OutputDirectory 'soft-telecine-metadata.json'
if((Invoke-Logged $Python @((Join-Path $PSScriptRoot 'prepare-edge-fixtures.py'),'mpeg2-soft-telecine',$fixtures[1].path,$softES,$softMetadata) 'soft-mutate.log') -ne 0){throw 'Soft telecine mutation failed'}
if((Invoke-Logged $FFmpeg @('-hide_banner','-loglevel','warning','-fflags','+genpts','-i',$softES,'-c','copy','-y',$soft) 'soft-container.log') -ne 0){throw 'Soft telecine container creation failed'}
$fixtures+=@{name='h264-no-timing';path=$noTiming;sha256=(Get-FileHash -LiteralPath $noTiming).Hash;mutation=$noTimingMetadata}
$fixtures+=@{name='soft-telecine';path=$soft;sha256=(Get-FileHash -LiteralPath $soft).Hash;mutation=$softMetadata}
$softTffES=Join-Path $OutputDirectory 'soft-telecine-fixed-tff.m2v'
$softTff=Join-Path $OutputDirectory 'soft-telecine-fixed-tff.mkv'
$softTffMetadata=Join-Path $OutputDirectory 'soft-telecine-fixed-tff-metadata.json'
if((Invoke-Logged $Python @((Join-Path $PSScriptRoot 'prepare-edge-fixtures.py'),'mpeg2-soft-telecine',$fixtures[1].path,$softTffES,$softTffMetadata,'--fixed-tff') 'soft-fixed-tff-mutate.log') -ne 0){throw 'Soft telecine fixed-TFF mutation failed'}
if((Invoke-Logged $FFmpeg @('-hide_banner','-loglevel','warning','-fflags','+genpts','-i',$softTffES,'-c','copy','-y',$softTff) 'soft-fixed-tff-container.log') -ne 0){throw 'Soft telecine fixed-TFF container creation failed'}
$fixtures+=@{name='soft-telecine-fixed-tff';path=$softTff;sha256=(Get-FileHash -LiteralPath $softTff).Hash;mutation=$softTffMetadata}
$progressiveRepeatES=Join-Path $OutputDirectory 'progressive-repeat.m2v'
$progressiveRepeat=Join-Path $OutputDirectory 'progressive-repeat.mkv'
$progressiveRepeatMetadata=Join-Path $OutputDirectory 'progressive-repeat-metadata.json'
if((Invoke-Logged $Python @((Join-Path $PSScriptRoot 'prepare-edge-fixtures.py'),'mpeg2-progressive-repeat',$fixtures[1].path,$progressiveRepeatES,$progressiveRepeatMetadata) 'progressive-repeat-mutate.log') -ne 0){throw 'Progressive repeat mutation failed'}
if((Invoke-Logged $FFmpeg @('-hide_banner','-loglevel','warning','-fflags','+genpts','-i',$progressiveRepeatES,'-c','copy','-y',$progressiveRepeat) 'progressive-repeat-container.log') -ne 0){throw 'Progressive repeat container creation failed'}
$fixtures+=@{name='progressive-repeat';path=$progressiveRepeat;sha256=(Get-FileHash -LiteralPath $progressiveRepeat).Hash;mutation=$progressiveRepeatMetadata}
$h264=Run-Graph 'h264-no-timing-double' $noTiming 'adaptive-double'
Verify ($h264.input_avg_duration -eq 400000) 'H264 fixture does not advertise its known 25 fps container rate'
foreach($segment in $h264.segments){
    $frames=@($segment.frame_data)
    if($segment.name -in 'whole-file','whole-replay'){Verify ($frames.Count -eq 200 -and $frames[0].start -eq 0) "H264 no-timing whole coverage differs: $($segment.name)"}
    for($index=0;$index -lt $frames.Count;++$index){
        Verify ($frames[$index].avg_duration -eq 200000 -and $frames[$index].stop-$frames[$index].start -eq 200000) "H264 no-timing field duration differs: $($segment.name)"
        if($index){Verify ($frames[$index].start-$frames[$index-1].start -eq 200000) "H264 no-timing field cadence differs: $($segment.name)"}
    }
}
$default=Run-Probe 'default-cuvid-no-timing' $noTiming 'default-cuvid'
Verify ($default.decoder -eq 'h264_cuvid' -and $default.count -eq 200) 'Default CUVID API field coverage differs'
Verify ($default.output_framerate[0] -eq 50*$default.output_framerate[1]) 'Default CUVID API omits the double-rate multiplier'
$defaultOffset=($default.frames[1].pts-$default.frames[0].pts)*10000000L*$default.input_time_base[0]/$default.input_time_base[1]
Verify ($defaultOffset -eq 200000L) 'Default CUVID API first second-field is not 20 ms'
$progressiveRepeatCPU=Run-Probe 'progressive-repeat-software-reference' $progressiveRepeat 'software'
$progressiveRepeatGPU=Run-Probe 'progressive-repeat-dynamic-auto' $progressiveRepeat 'dynamic-auto'
$progressiveRepeatPixels=Oracle-Hashes 'progressive-repeat-weave-reference' $progressiveRepeat @()
Verify ($progressiveRepeatCPU.count -eq 100 -and $progressiveRepeatGPU.count -eq 100 -and $progressiveRepeatPixels.Count -eq 100) 'Progressive sequence RFF changes picture coverage'
for($index=0;$index -lt [Math]::Min(100,$progressiveRepeatGPU.count);++$index){
    $frame=$progressiveRepeatGPU.frames[$index]
    Verify ($frame.processed -eq '0' -and $frame.sha256 -eq $progressiveRepeatPixels[$index]) 'Auto adaptive processes progressive-sequence RFF pictures'
    Verify ([bool]$frame.repeat_pict -eq [bool]$progressiveRepeatCPU.frames[$index].repeat_pict) 'Progressive sequence RFF loses repeat metadata'
}
$cpu=Run-Probe 'soft-telecine-software-reference' $soft 'software'
Verify ($cpu.decoder -eq 'mpeg2video' -and $cpu.count -eq 100) 'Independent software telecine reference has wrong picture coverage'
Verify (@($cpu.frames|Where-Object repeat_pict -EQ 1).Count -eq 50 -and @($cpu.frames|Where-Object interlaced -EQ $true).Count -eq 0) 'Independent decoder did not observe progressive pictures with alternating RFF'
$weaveHashes=Oracle-Hashes 'soft-telecine-weave-reference' $soft @()
Verify ($weaveHashes.Count -eq $cpu.count) 'Independent woven GPU reference coverage differs'
$auto=Run-Graph 'soft-telecine-auto-double' $soft 'adaptive-double'
$aggressive=Run-Graph 'soft-telecine-aggressive-double' $soft 'adaptive-aggressive-double'
$force=Run-Graph 'soft-telecine-force-double' $soft 'adaptive-force-double'
foreach($report in @($auto,$aggressive,$force)){
    $forced=$report.deint -eq 'adaptive-force-double'
    foreach($segment in $report.segments|Where-Object name -In 'whole-file','whole-replay'){
        $frames=@($segment.frame_data)
        Verify ($frames.Count -eq $cpu.count*$(if($forced){2}else{1})) "Soft telecine output count differs: $($report.deint)/$($segment.name)"
        if($frames.Count -ne $cpu.count*$(if($forced){2}else{1})){continue}
        for($picture=0;$picture -lt $cpu.count;++$picture){
            $reference=$cpu.frames[$picture]
            $start=[long]($reference.pts*10000000L*$cpu.input_time_base[0]/$cpu.input_time_base[1])
            $duration=400000L*$(if($reference.repeat_pict){1.5}else{1})
            for($field=0;$field -lt $(if($forced){2}else{1});++$field){
                $frame=$frames[$picture*$(if($forced){2}else{1})+$field]
                $interval=[long]($duration/$(if($forced){2}else{1}))
                Verify ($frame.start -eq $start+$field*$interval -and $frame.stop-$frame.start -eq $interval) "Soft telecine RFF display interval differs: $($report.deint)/$($segment.name)/$picture/$field"
                Verify (($frame.flags -band 8) -eq 8) "Soft telecine delivered non-progressive picture: $($report.deint)/$picture"
                Verify (($frame.flags -band 64) -eq $(if(-not $forced -and $reference.repeat_pict){64}else{0})) "Soft telecine repeat flag differs: $($report.deint)/$picture"
                if(-not $forced -and $reference.repeat_pict){Verify (($frame.flags -band 4) -eq $(if($reference.top_field_first){4}else{0})) "Soft telecine raw picture field order differs: $($segment.name)/$picture"}
            }
        }
    }
}
$softTffOracle=Oracle-Hashes 'soft-telecine-fixed-tff-adaptive-reference' $softTff @() 'adaptive'
$softTffGPU=Run-Graph 'soft-telecine-fixed-tff-auto-double' $softTff 'adaptive-double'
foreach($segment in $softTffGPU.segments|Where-Object name -In 'whole-file','whole-replay'){
    Verify ($segment.frames -eq 100 -and (@($segment.frame_data|ForEach-Object sha256)-join ',') -eq ($softTffOracle-join ',')) "Soft telecine single adaptive pixels differ from independent same-field oracle: $($segment.name)"
}
$liveRecords=@()
$gpuControl=Run-Graph 'live-static-hardware-force' $fixtures[2].path 'adaptive-force-double'
foreach($algorithm in 'yadif','bwdif'){
    $control=Run-Graph "live-static-$algorithm" $fixtures[2].path "force-$algorithm"
    $oracle=Oracle-Hashes "live-$algorithm-reference" $fixtures[2].path @('-vf',"$algorithm=mode=send_field:parity=auto:deint=all")
    $static=@($control.segments[0].frame_data)
    Verify ($static.Count -eq 400 -and $oracle.Count -eq 400) "Software deinterlacing control field coverage differs: $algorithm"
    Verify ((@($static|ForEach-Object sha256)-join ',') -eq ($oracle-join ',')) "Static software field pixels differ from independent standalone oracle: $algorithm"
    $live=Run-Graph "live-hardware-to-$algorithm" $fixtures[2].path 'adaptive-force-double' $algorithm
    Verify ($live.segments.Count -eq 1) "Live software transition restarted graph: $algorithm"
    $frames=@($live.segments[0].frame_data)
    Verify ($frames.Count -eq 400) "Live software transition duplicates or loses fields: $algorithm ($($frames.Count))"
    for($index=0;$index -lt $frames.Count;++$index){
        $frame=$frames[$index]
        Verify ($frame.start -eq $index*200000L -and $frame.stop-$frame.start -eq 200000L -and $frame.avg_duration -eq 200000L) "Live software transition repeats hardware processing or overlaps fields: $algorithm"
    }
    $phaseOne=@($frames|Where-Object phase -EQ 1)
    Verify ($phaseOne.Count -ge 30) "Live software phase too short: $algorithm"
    foreach($frame in $phaseOne|Select-Object -Last 20){
        $index=[int]($frame.start/200000L)
        Verify ($frame.sha256 -eq $oracle[$index]) "Stable live software pixels differ from independent oracle: $algorithm/$index"
    }
    # Before switching, the decoder retains pictures in its display queue. The
    # first old processed picture delivered after the gate must retain its exact
    # hardware pixels, rather than passing through Force + software again.
    $queued=@($phaseOne|Select-Object -First 2)
    foreach($frame in $queued){
        $index=[int]($frame.start/200000L)
        Verify ($frame.sha256 -eq $gpuControl.segments[0].frame_data[$index].sha256) "Queued hardware fields were software filtered again: $algorithm/$index"
    }
    $liveRecords+=@{algorithm=$algorithm;frames=$frames.Count;first_new_phase_start=$phaseOne[0].start;queued_hardware_fields=$queued.Count;standalone_reference_frames=$oracle.Count}
}
foreach($binary in $binaries){Verify ((Get-FileHash -LiteralPath (Join-Path $Package $binary.file)).Hash -eq $binary.sha256) "Candidate changed during test: $($binary.file)"}
foreach($fixture in $fixtures){Verify ((Get-FileHash -LiteralPath $fixture.path).Hash -eq $fixture.sha256) "Fixture changed: $($fixture.name)"}
Verify ((Get-FileHash -LiteralPath $HarnessPath).Hash -eq $harnessHash) 'Harness changed during test'
Verify ((Get-FileHash -LiteralPath $ProbePath).Hash -eq $probeHash) 'Probe changed during test'
$summary=[ordered]@{scope='Synthetic H264 absent SPS timing, default FFmpeg CUVID API cadence, MPEG2 progressive-picture soft telecine repeat display intervals, and Force hardware-to-YADIF/BWDIF continuous transition. Software codec path independently supplies repeat/time metadata; standalone woven CUVID supplies progressive-sequence pixels and software filter pixels; standalone adaptive single supplies same-TFF soft telecine pixels. Force quality is not independently judged; its RFF-aware field timing and flags are verified.';platform=$Platform;package=$Package;candidate_binary_sha256=$binaries;harness=$HarnessPath;harness_sha256=$harnessHash;probe=$ProbePath;probe_sha256=$probeHash;source_sha256=@($sources);ffmpeg=$FFmpeg;ffmpeg_sha256=(Get-FileHash -LiteralPath $FFmpeg).Hash;started_utc=$started;completed_utc=[DateTime]::UtcNow.ToString('o');fixtures=$fixtures;graphs=@($graphRecords);default_api_first_field_ticks=$defaultOffset;soft_telecine_reference_pictures=$cpu.count;live_software=$liveRecords;passed=($failures.Count -eq 0);failures=@($failures)}
Write-Crlf (Join-Path $OutputDirectory 'validation.json') ($summary|ConvertTo-Json -Depth 14)
if(-not $summary.passed){throw "$($failures.Count) edge regressions failed; see validation.json"}
Write-Output 'CUVID cadence, soft telecine and software transition edge regressions passed.'
