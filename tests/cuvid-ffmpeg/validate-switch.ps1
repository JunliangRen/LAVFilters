param(
    [Parameter(Mandatory=$true)][string]$Package,
    [ValidateSet('x64','x86')][string]$Platform='x64',
    [string]$HarnessPath,
    [string]$OutputDirectory,
    [string]$FFmpeg='C:\Windows\ffmpeg.exe',
    [switch]$SkipDeviceProbe
)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $HarnessPath){$HarnessPath=Join-Path $root "bin_build\cuvid-ffmpeg-20261011\fix4\harness\$Platform\graph-regression-$Platform.exe"}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root "bin_build\cuvid-ffmpeg-20261011\fix4\switch-$Platform"}
$Package=(Resolve-Path -LiteralPath $Package).Path
$HarnessPath=(Resolve-Path -LiteralPath $HarnessPath).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory|Out-Null
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
if(@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count){throw 'Use a fresh OutputDirectory to preserve prior evidence.'}
$failures=[Collections.Generic.List[string]]::new()
$graphs=[Collections.Generic.List[object]]::new()
function Verify([bool]$Condition,[string]$Message){if(-not $Condition -and -not $failures.Contains($Message)){$failures.Add($Message);Write-Warning $Message}}
function Write-Crlf([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,($Text -replace '\r?\n',"`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))}
function Invoke-Logged([string]$Executable,[object[]]$Arguments,[string]$Log){
    $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{& $Executable @Arguments 2>&1|Out-File -LiteralPath (Join-Path $OutputDirectory $Log) -Encoding utf8;$code=$LASTEXITCODE}
    finally{$ErrorActionPreference=$previous}
    return $code
}
function Run-Graph([string]$Id,[string]$Mode,[string]$Live='',[long]$Device=-1){
    $path=Join-Path $OutputDirectory "$Id.json"
    $arguments=@($Package,$fixture,8,1,$path,'NV12',6,$Mode,'cuvid (ffmpeg)',$Device,120000)
    if($Live){$arguments+=@('-',$Live)}
    $code=Invoke-Logged $HarnessPath $arguments "$Id.log"
    Verify ($code -eq 0) "Graph failed: $Id ($code)"
    if(-not(Test-Path -LiteralPath $path)){throw "Missing graph report: $Id"}
    $report=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    Verify ($report.pointer_bits -eq $(if($Platform -eq 'x64'){64}else{32})) "Process architecture differs: $Id"
    Verify ($report.input_avg_duration -eq 400000 -and $report.duration -eq 80000000) "Source rate/duration differs: $Id"
    foreach($segment in $report.segments){
        Verify ($segment.pass -and $segment.hr -eq 0 -and $segment.event -eq 1) "EOS/status failure: $Id/$($segment.name)"
        Verify ($segment.decoder -eq 'cuvid (ffmpeg)' -and $segment.active_device) "GPU fallback: $Id/$($segment.name)"
        foreach($frame in $segment.frame_data){Verify ($frame.decoder -eq 'cuvid (ffmpeg)') "Per-frame GPU fallback: $Id/$($segment.name)"}
    }
    $graphs.Add(@{id=$Id;path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash;segments=$report.segments.Count})
    return $report
}
function Oracle([string]$Id,[string]$Deint,[string]$Filter='',[bool]$Single=$false){
    $path=Join-Path $OutputDirectory "$Id.framehash.txt"
    $arguments=@('-hide_banner','-loglevel','warning','-c:v','mpeg2_cuvid','-deint',$Deint)
    if($Deint -eq 'adaptive'){$arguments+=@('-drop_second_field',$(if($Single){'1'}else{'0'}))}
    $arguments+=@('-i',$fixture,'-an')
    if($Filter){$arguments+=@('-vf',$Filter)}
    $arguments+=@('-fps_mode','passthrough','-pix_fmt','yuv420p','-f','framehash','-hash','sha256','-y',$path)
    Verify ((Invoke-Logged $FFmpeg $arguments "$Id.log") -eq 0) "Standalone oracle failed: $Id"
    Write-Crlf $path ([IO.File]::ReadAllText($path).TrimEnd())
    return @(Get-Content -LiteralPath $path|Where-Object{$_ -match '^0,'}|ForEach-Object{($_ -split ',')[-1].Trim()})
}
function Check-Timeline($Report,[long]$Step,[string]$Id){
    $frames=@($Report.segments[0].frame_data)
    Verify ($frames.Count -eq $sourcePictures*400000L/$Step) "Every source picture/field is not covered: $Id ($($frames.Count) outputs)"
    $continuous=$true;$rates=$true
    for($index=0;$index -lt $frames.Count;++$index){
        $frame=$frames[$index]
        $continuous=$continuous -and $frame.start -eq $index*$Step -and $frame.stop -eq ($index+1)*$Step
        $rates=$rates -and $frame.avg_duration -eq $Step
    }
    Verify $continuous "Whole-file picture/field time coverage differs: $Id"
    Verify $rates "Output media rate differs: $Id"
}
$started=[DateTime]::UtcNow.ToString('o')
$binaries=@(Get-ChildItem -LiteralPath $Package -File|Where-Object Extension -In '.dll','.ax'|Sort-Object Name|ForEach-Object{@{file=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
$harnessHash=(Get-FileHash -LiteralPath $HarnessPath).Hash
$sources=@('graph-regression.cpp','validate-switch.ps1')|ForEach-Object{@{file=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash}}
$fixture=Join-Path $OutputDirectory 'live-mpeg2-tff.mkv'
$encodeArguments=@('-hide_banner','-loglevel','warning','-f','lavfi','-i','testsrc2=size=320x240:rate=50:duration=8','-an','-vf','tinterlace=interleave_top','-flags','+ilme+ildct','-field_order','tt','-c:v','mpeg2video','-g','12','-bf','2','-q:v','3','-pix_fmt','yuv420p','-y',$fixture)
if((Invoke-Logged $FFmpeg $encodeArguments 'encode.log') -ne 0){throw 'Fixture generation failed'}
$fixtureHash=(Get-FileHash -LiteralPath $fixture).Hash
$woven=Oracle 'source-woven' 'weave'
$sourcePictures=$woven.Count
Verify ($sourcePictures -eq 200) 'Independent source picture count differs'
$records=@()
foreach($single in $false,$true){
    $rate=if($single){'single'}else{'double'}
    $step=if($single){400000L}else{200000L}
    $hw=Oracle "hardware-$rate" 'adaptive' '' $single
    $hwReport=Run-Graph "static-hardware-$rate" $(if($single){'adaptive-force'}else{'adaptive-force-double'})
    Check-Timeline $hwReport $step "static-hardware-$rate"
    Verify ($hw.Count -eq $sourcePictures*400000L/$step) "Hardware oracle count differs: $rate"
    Verify ((@($hwReport.segments[0].frame_data|ForEach-Object sha256)-join ',') -eq ($hw-join ',')) "Static hardware pixels differ from independent oracle: $rate"
    foreach($algorithm in 'yadif','bwdif'){
        $filter="$algorithm=mode=$(if($single){'send_frame'}else{'send_field'}):parity=tff:deint=all"
        $sw=Oracle "software-$algorithm-$rate" 'weave' $filter
        $mode="force-$algorithm"+$(if($single){'-single'}else{''})
        $control=Run-Graph "static-$algorithm-$rate" $mode
        Check-Timeline $control $step "static-$algorithm-$rate"
        Verify ($sw.Count -eq $sourcePictures*400000L/$step) "Software oracle count differs: $algorithm/$rate"
        Verify ((@($control.segments[0].frame_data|ForEach-Object sha256)-join ',') -eq ($sw-join ',')) "Static software pixels differ from independent oracle: $algorithm/$rate"
        foreach($scenario in 'sw-to-hw','sw-hw-sw'){
            $id="$scenario-$algorithm-$rate"
            $live=Run-Graph $id $mode $scenario
            Check-Timeline $live $step $id
            $changes=@($live.live_changes)
            $expectedChanges=if($scenario -eq 'sw-hw-sw'){2}else{1}
            Verify ($changes.Count -eq $expectedChanges) "Missing running settings gates: $id"
            # A fixed one-second window on each side of the *input packet* gate
            # excludes different filter edge padding and queued source history.
            # This margin is predetermined, never inferred from pixel mismatch.
            $first=[long]$changes[0].gate_packet_start
            $last=if($expectedChanges -eq 2){[long]$changes[-1].gate_packet_start}else{80000000L}
            $swCompared=0;$hwCompared=0
            foreach($frame in $live.segments[0].frame_data){
                $index=[int]($frame.start/$step)
                if($frame.start -lt $first-10000000L -or ($expectedChanges -eq 2 -and $frame.start -ge $last+10000000L)){
                    Verify ($index -lt $sw.Count -and $frame.sha256 -eq $sw[$index]) "Stable software pixels differ from independent oracle: $id/$index"
                    ++$swCompared
                }elseif($frame.start -ge $first+10000000L -and $frame.start -lt $last-10000000L){
                    Verify ($index -lt $hw.Count -and $frame.sha256 -eq $hw[$index]) "Stable hardware pixels differ from independent oracle: $id/$index"
                    ++$hwCompared
                }
            }
            Verify ($swCompared -ge 25 -and $hwCompared -ge 25) "Stable independent pixel windows too short: $id"
            $records+=@{id=$id;source_pictures=$sourcePictures;output_count=$live.segments[0].frames;expected_step=$step;changes=$changes;stable_software_pixels=$swCompared;stable_hardware_pixels=$hwCompared;standalone_software_reference_frames=$sw.Count;standalone_hardware_reference_frames=$hw.Count}
        }
    }
}
$deviceRecords=@()
if(-not $SkipDeviceProbe){
    $automatic=Run-Graph 'device-automatic' 'weave' '' -1
    $zero=Run-Graph 'device-zero' 'weave' '' 0
    $count=@($automatic.devices).Count
    Verify ($count -gt 0) 'No CUDA devices for normalization regression'
    $invalid=Run-Graph 'device-invalid' 'weave' '' ($count+99)
    Verify ($automatic.returned_device -eq 4294967295 -and $automatic.device_selection_row -eq 0) 'Automatic device round trip differs'
    Verify ($zero.returned_device -eq 0 -and $zero.device_selection_row -eq 1) 'Valid GPU 0 was normalized incorrectly'
    Verify ($invalid.returned_device -eq 4294967295 -and $invalid.returned_device_identifier -eq 0 -and $invalid.device_after_apply -eq 4294967295 -and $invalid.device_selection_row -eq 0) 'Invalid CUDA ordinal does not select and apply Automatic'
    foreach($report in $automatic,$zero,$invalid){
        Check-Timeline $report 400000L 'device-normalization'
        Verify ($report.active_device -eq $automatic.devices[0].name) 'Automatic/invalid CUDA ordinal does not decode on GPU 0'
        Verify ((@($report.segments[0].frame_data|ForEach-Object sha256)-join ',') -eq ($woven-join ',')) 'Device selection pixels differ from independent weave oracle'
        $deviceRecords+=@{requested=$report.requested_device;returned=$report.returned_device;identifier=$report.returned_device_identifier;after_apply=$report.device_after_apply;selection_row=$report.device_selection_row;active_device=$report.active_device;frames=$report.segments[0].frames}
    }
}
foreach($binary in $binaries){Verify ((Get-FileHash -LiteralPath (Join-Path $Package $binary.file)).Hash -eq $binary.sha256) "Candidate changed during test: $($binary.file)"}
Verify ((Get-FileHash -LiteralPath $fixture).Hash -eq $fixtureHash) 'Fixture changed during test'
Verify ((Get-FileHash -LiteralPath $HarnessPath).Hash -eq $harnessHash) 'Harness changed during test'
$summary=[ordered]@{scope='Continuous runtime Force software-to-hardware and software-hardware-software transitions for YADIF/BWDIF, single/double output. All source picture/field time slots and EOS are required; stable pixel windows compare independent standalone CUVID adaptive or woven-CUVID plus software filters. Boundary padding pixels are not judged. Runtime-only saved invalid CUDA ordinal tests getter, Automatic UI row mapping and Apply after decoder connection; no registry or system settings are written.';platform=$Platform;package=$Package;candidate_binary_sha256=$binaries;harness=$HarnessPath;harness_sha256=$harnessHash;source_sha256=@($sources);ffmpeg=$FFmpeg;ffmpeg_sha256=(Get-FileHash -LiteralPath $FFmpeg).Hash;started_utc=$started;completed_utc=[DateTime]::UtcNow.ToString('o');fixture=@{path=$fixture;sha256=$fixtureHash;encode_arguments=$encodeArguments;independent_source_pictures=$sourcePictures};graphs=@($graphs);transitions=$records;devices=$deviceRecords;device_probe_skipped=[bool]$SkipDeviceProbe;passed=($failures.Count -eq 0 -and -not $SkipDeviceProbe);failures=@($failures)}
Write-Crlf (Join-Path $OutputDirectory 'validation.json') ($summary|ConvertTo-Json -Depth 14)
if(-not $summary.passed){throw "$($failures.Count) transition/device regressions failed (device probe skipped: $SkipDeviceProbe); see validation.json"}
Write-Output 'CUVID continuous software/hardware transitions and CUDA device normalization passed.'
