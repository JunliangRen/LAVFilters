param(
    [Parameter(Mandatory=$true)][string]$CoreReport,
    [Parameter(Mandatory=$true)][string]$EightKReport,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$SmokeExecutable
)
$ErrorActionPreference='Stop'
$CoreReport=(Resolve-Path -LiteralPath $CoreReport).Path
$EightKReport=(Resolve-Path -LiteralPath $EightKReport).Path
if(Test-Path -LiteralPath $OutputPath) {throw 'Choose a new OutputPath to preserve the compact summary'}
$core=Get-Content -LiteralPath $CoreReport -Raw | ConvertFrom-Json
$eight=Get-Content -LiteralPath $EightKReport -Raw | ConvertFrom-Json
$architecture=$core.platform
$failures=[Collections.Generic.List[string]]::new()
function Verify([bool]$Condition,[string]$Message) {if(-not $Condition) {$failures.Add($Message);Write-Warning $Message}}
Verify $core.passed 'Core decode regression did not pass'
Verify $eight.passed 'Unchanged actual 8K short-prefix validation did not pass'
Verify ($architecture -eq $eight.architecture) 'Core and 8K test architectures differ'
Verify ($core.package -eq $eight.package) 'Core and 8K candidates differ'
$hashes=@{}
foreach($binary in $core.candidate_binary_sha256) {
    $hashes[$binary.file]=$binary.sha256
    Verify ((Get-FileHash -LiteralPath (Join-Path $core.package $binary.file) -Algorithm SHA256).Hash -eq $binary.sha256) "Candidate binary changed since core regression: $($binary.file)"
    Verify ($eight.candidate_binary_sha256.($binary.file) -eq $binary.sha256) "8K candidate hash differs: $($binary.file)"
}
Verify ((Get-FileHash -LiteralPath $core.harness -Algorithm SHA256).Hash -eq $core.harness_sha256) 'Core graph harness changed'
Verify ($core.harness_sha256 -eq $eight.harness_sha256) 'Core and 8K graph harnesses differ'
if(-not $SmokeExecutable) {$SmokeExecutable=Join-Path (Split-Path $core.harness -Parent) "smoke-load-$architecture.exe"}
$SmokeExecutable=(Resolve-Path -LiteralPath $SmokeExecutable).Path
$directory=Split-Path $OutputPath -Parent
if($directory) {New-Item -ItemType Directory -Force -Path $directory | Out-Null}
$smokeLog=[IO.Path]::ChangeExtension($OutputPath,'loadsmoke.log')
& $SmokeExecutable $core.package 2>&1 | Out-File -LiteralPath $smokeLog -Encoding utf8
$smokeExit=$LASTEXITCODE
$smokeText=Get-Content -LiteralPath $smokeLog -Raw
$smokeCases=@($smokeText -split '\r?\n' | Where-Object {$_ -match '^PASS '}).Count
$pointerBits=if($architecture -eq 'x64') {64} else {32}
Verify ($smokeExit -eq 0 -and $smokeCases -eq 5) 'Native filter/dependency loadsmoke failed'
Verify ($smokeText.Contains("pointer_bits=$pointerBits")) 'Native smoke process architecture differs'
$report=[pscustomobject]@{
    passed=($failures.Count -eq 0)
    architecture=$architecture
    pointer_bits=$pointerBits
    package=$core.package
    tested_utc=$core.tested_utc
    completed_utc=[DateTime]::UtcNow.ToString('o')
    candidate_binary_sha256=$hashes
    candidate_binary_count=$hashes.Count
    core=[pscustomobject]@{
        passed=$core.passed
        report=$CoreReport
        report_sha256=(Get-FileHash -LiteralPath $CoreReport -Algorithm SHA256).Hash
        graph_runs=$core.graph_runs
        segment_runs=$core.segment_runs
        fixture_count=$core.fixture_count
        official_fixture_count=$core.official_fixture_count
        synthetic_fixture_count=$core.synthetic_fixture_count
        output_case_count=$core.output_case_count
        fixture_manifest_sha256=$core.fixture_manifest_sha256
        decoder_threads=@($core.records.threads | Sort-Object -Unique)
        strict_seek_coverage=$true
        whole_file_counts_md5_ordered_sha256=$true
        eos_and_whole_replay=$true
        thread_pixel_and_timestamp_parity=$true
    }
    harness=[pscustomobject]@{path=$core.harness;sha256=$core.harness_sha256;pointer_bits=$pointerBits}
    loadsmoke=[pscustomobject]@{passed=($smokeExit -eq 0 -and $smokeCases -eq 5);cases=$smokeCases;exit_code=$smokeExit;executable=$SmokeExecutable;sha256=(Get-FileHash -LiteralPath $SmokeExecutable -Algorithm SHA256).Hash;log=$smokeLog}
    actual_8k_short_prefix=[pscustomobject]@{
        passed=$eight.passed
        report=$EightKReport
        report_sha256=(Get-FileHash -LiteralPath $EightKReport -Algorithm SHA256).Hash
        fixture=$eight.fixture
        fixture_sha256=$eight.fixture_sha256
        fixture_bytes=$eight.fixture_bytes
        fixture_modified=$eight.fixture_modified
        width=$eight.width
        height=$eight.height
        bits=$eight.bits
        output_format=$eight.output_format
        whole_frames=$eight.expected_whole_frames
        decoder_threads=@($eight.records.threads)
        graph_runs=$eight.graph_runs
        segment_runs=$eight.segment_runs
        results=@($eight.records | Select-Object threads,whole_frames,whole_md5,bytes,precision_samples,seek_coverage)
        pixel_reference=$eight.pixel_reference
        incomplete_tail_thread_comparison=$eight.incomplete_tail_thread_comparison
        reference_limits=$eight.reference_limits
        limits=$eight.limits
    }
    limits='Core results cover selected official-source short fixtures and synthetic stride cases. The actual 8K result covers only an unchanged 64 MiB prefix with explicitly selected low decoder threads. x86 core success does not establish 8K default-auto-thread playback or sufficient 32-bit address space for arbitrary inputs. No sustained playback, renderer, audio/video sync, or real-time performance claim.'
    failures=@($failures)
}
$text=$report | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($OutputPath,($text -replace '\r?\n',"`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))
if(-not $report.passed) {throw "$($failures.Count) compact-summary failures; see $OutputPath"}
Write-Output "$architecture compact validation passed: $($core.graph_runs) core graphs/$($core.segment_runs) segments, $($eight.graph_runs) actual 8K graph(s), $smokeCases native load checks"
