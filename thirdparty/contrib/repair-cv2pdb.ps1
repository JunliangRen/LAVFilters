[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Original,
    [Parameter(Mandatory = $true)][string]$Converted
)

# cv2pdb keeps runtime RVAs but omits GNU COFF strings referenced by /offset
# section names. Restore that metadata without changing CodeView or runtime data.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Check-Range([byte[]]$Data, [long]$Offset, [long]$Length) {
    if ($Offset -lt 0 -or $Length -lt 0 -or $Offset -gt $Data.LongLength - $Length) {
        throw 'Invalid PE file range'
    }
}
function Read-U16([byte[]]$Data, [long]$Offset) {
    Check-Range $Data $Offset 2
    [BitConverter]::ToUInt16($Data, [int]$Offset)
}
function Read-U32([byte[]]$Data, [long]$Offset) {
    Check-Range $Data $Offset 4
    [BitConverter]::ToUInt32($Data, [int]$Offset)
}
function Read-String([byte[]]$Data, [long]$Offset, [long]$Limit) {
    Check-Range $Data $Offset ($Limit - $Offset)
    $End = $Offset
    while ($End -lt $Limit -and $Data[$End] -ne 0) { $End++ }
    if ($End -eq $Limit) { throw 'Unterminated COFF string' }
    [Text.Encoding]::ASCII.GetString($Data, [int]$Offset, [int]($End - $Offset))
}
function Parse-PE([byte[]]$Data) {
    if ((Read-U16 $Data 0) -ne 0x5a4d) { throw 'Invalid MZ signature' }
    $Pe = Read-U32 $Data 0x3c
    if ((Read-U32 $Data $Pe) -ne 0x4550) { throw 'Invalid PE signature' }
    $Coff = $Pe + 4
    $Optional = $Coff + 20
    $OptionalSize = Read-U16 $Data ($Coff + 16)
    Check-Range $Data $Optional $OptionalSize
    $Magic = Read-U16 $Data $Optional
    if ($Magic -eq 0x10b) { $Directory = $Optional + 96 }
    elseif ($Magic -eq 0x20b) { $Directory = $Optional + 112 }
    else { throw 'Unsupported PE optional header' }
    if ($Directory + 16 * 8 -gt $Optional + $OptionalSize -or
        (Read-U32 $Data ($Directory - 4)) -lt 16) { throw 'Missing PE data directories' }
    $SymbolPointer = Read-U32 $Data ($Coff + 8)
    $SymbolCount = Read-U32 $Data ($Coff + 12)
    $Strings = 0L
    $StringSize = 0L
    if ($SymbolPointer) {
        Check-Range $Data $SymbolPointer ([long]$SymbolCount * 18)
        $Strings = $SymbolPointer + [long]$SymbolCount * 18
        $StringSize = Read-U32 $Data $Strings
        if ($StringSize -lt 4) { throw 'Invalid COFF string table size' }
        Check-Range $Data $Strings $StringSize
    } elseif ($SymbolCount) { throw 'COFF symbol count without table' }
    $Sections = @()
    $Count = Read-U16 $Data ($Coff + 2)
    $Table = $Optional + $OptionalSize
    Check-Range $Data $Table ([long]$Count * 40)
    for ($Index = 0; $Index -lt $Count; $Index++) {
        $Entry = $Table + $Index * 40
        $Name = [Text.Encoding]::ASCII.GetString($Data, $Entry, 8).TrimEnd([char]0)
        $VirtualSize = Read-U32 $Data ($Entry + 8)
        $Rva = Read-U32 $Data ($Entry + 12)
        $RawSize = Read-U32 $Data ($Entry + 16)
        $RawPointer = Read-U32 $Data ($Entry + 20)
        Check-Range $Data $RawPointer $RawSize
        $Sections += [pscustomobject]@{
            Name = $Name; Entry = $Entry; VirtualSize = $VirtualSize; Rva = $Rva
            RawSize = $RawSize; RawPointer = $RawPointer
            Flags = Read-U32 $Data ($Entry + 36)
        }
    }
    [pscustomobject]@{ Coff = $Coff; Optional = $Optional; Directory = $Directory
        Magic = $Magic; Strings = $Strings; StringSize = $StringSize; Sections = $Sections }
}
function Section-Name([byte[]]$Data, $Pe, $Section) {
    if (-not $Section.Name.StartsWith('/')) { return $Section.Name }
    $Offset = 0L
    if (-not [long]::TryParse($Section.Name.Substring(1), [ref]$Offset) -or
        -not $Pe.Strings -or $Offset -lt 4 -or $Offset -ge $Pe.StringSize) {
        throw 'Invalid COFF long section name'
    }
    Read-String $Data ($Pe.Strings + $Offset) ($Pe.Strings + $Pe.StringSize)
}
function Rva-Offset([byte[]]$Data, $Pe, [long]$Rva, [long]$Size) {
    foreach ($Section in $Pe.Sections) {
        $Delta = $Rva - $Section.Rva
        if ($Delta -ge 0 -and $Delta + $Size -le $Section.RawSize) {
            Check-Range $Data ($Section.RawPointer + $Delta) $Size
            return $Section.RawPointer + $Delta
        }
    }
    throw 'Unmapped PE RVA'
}
function Section-Hash([byte[]]$Data, $Section) {
    $Sha = [Security.Cryptography.SHA256]::Create()
    try {
        [BitConverter]::ToString($Sha.ComputeHash($Data, [int]$Section.RawPointer, [int]$Section.RawSize))
    } finally { $Sha.Dispose() }
}

$OriginalPath = [IO.Path]::GetFullPath($Original)
$ConvertedPath = [IO.Path]::GetFullPath($Converted)
if ($OriginalPath -eq $ConvertedPath) { throw 'Original and converted paths must differ' }
$Before = [IO.File]::ReadAllBytes($OriginalPath)
$After = [IO.File]::ReadAllBytes($ConvertedPath)
$Source = Parse-PE $Before
$Target = Parse-PE $After
if (@($Target.Sections | Where-Object { $_.Name.StartsWith('/') }).Count -and -not $Target.Strings) {
    if (-not $Source.Strings) { throw 'Original COFF string table is missing' }
    $New = New-Object byte[] ($After.Length + $Source.StringSize)
    [Array]::Copy($After, $New, $After.Length)
    [Array]::Copy($Before, $Source.Strings, $New, $After.Length, $Source.StringSize)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$After.Length), 0, $New, $Target.Coff + 8, 4)
    # The restored table has strings only: no obsolete DWARF/COFF symbols.
    [Array]::Copy([BitConverter]::GetBytes([uint32]0), 0, $New, $Target.Coff + 12, 4)
    $After = $New
    $Target = Parse-PE $After
}

$Runtime = @{}
foreach ($Section in $Source.Sections) {
    $Name = Section-Name $Before $Source $Section
    if (-not $Name.StartsWith('.debug')) { $Runtime.Add($Name, $Section) }
}
$Seen = @{}
foreach ($Section in $Target.Sections) {
    $Name = Section-Name $After $Target $Section
    if ($Name -eq '.debug') { continue }
    if (-not $Runtime.ContainsKey($Name)) { throw "Unexpected converted section: $Name" }
    $OriginalSection = $Runtime[$Name]
    foreach ($Key in @('VirtualSize', 'Rva', 'RawSize', 'Flags')) {
        if ($OriginalSection.$Key -ne $Section.$Key) { throw "Changed runtime section $Name $Key" }
    }
    if ((Section-Hash $Before $OriginalSection) -ne (Section-Hash $After $Section)) {
        throw "Changed runtime section bytes: $Name"
    }
    if ($Seen.ContainsKey($Name)) { throw "Duplicate converted runtime section: $Name" }
    $Seen.Add($Name, $true)
}
if ($Seen.Count -ne $Runtime.Count) { throw 'Missing converted runtime section' }
if ($Source.Magic -ne $Target.Magic -or
    (Read-U16 $Before $Source.Coff) -ne (Read-U16 $After $Target.Coff)) { throw 'Changed PE architecture' }
# Entry point, image base, section/file alignment, subsystem and DLL flags.
foreach ($Pair in @(@(16, 4), @(24, 16), @(68, 4))) {
    $Left = [Convert]::ToBase64String($Before, $Source.Optional + $Pair[0], $Pair[1])
    $Right = [Convert]::ToBase64String($After, $Target.Optional + $Pair[0], $Pair[1])
    if ($Left -ne $Right) { throw 'Changed runtime PE header' }
}
for ($Index = 0; $Index -lt 16; $Index++) {
    if ($Index -eq 6) { continue }
    if ([Convert]::ToBase64String($Before, $Source.Directory + $Index * 8, 8) -ne
        [Convert]::ToBase64String($After, $Target.Directory + $Index * 8, 8)) {
        throw "Changed runtime data directory: $Index"
    }
}
$DebugRva = Read-U32 $After ($Target.Directory + 6 * 8)
$DebugSize = Read-U32 $After ($Target.Directory + 6 * 8 + 4)
if (-not $DebugRva -or $DebugSize -ne 28) { throw 'Missing single CodeView directory' }
$Debug = Rva-Offset $After $Target $DebugRva $DebugSize
if ((Read-U32 $After ($Debug + 12)) -ne 2) { throw 'Expected CodeView debug data' }
$CodeViewSize = Read-U32 $After ($Debug + 16)
$CodeViewRva = Read-U32 $After ($Debug + 20)
$CodeView = Read-U32 $After ($Debug + 24)
Check-Range $After $CodeView $CodeViewSize
if ($CodeViewSize -lt 25 -or (Read-U32 $After $CodeView) -ne 0x53445352 -or
    (Rva-Offset $After $Target $CodeViewRva $CodeViewSize) -ne $CodeView) { throw 'Invalid RSDS record' }
$PdbName = Read-String $After ($CodeView + 24) ($CodeView + $CodeViewSize)
if ([IO.Path]::GetFileName($PdbName) -ne [IO.Path]::ChangeExtension([IO.Path]::GetFileName($ConvertedPath), '.pdb')) {
    throw 'Unexpected CodeView PDB name'
}
# cv2pdb leaves the original checksum after rewriting the PE. Clear it rather
# than claim a checksum for the converted headers, sections and restored strings.
[Array]::Copy([BitConverter]::GetBytes([uint32]0), 0, $After, $Target.Optional + 64, 4)
[IO.File]::WriteAllBytes($ConvertedPath, $After)
Write-Output "Validated cv2pdb runtime and CodeView: $ConvertedPath"
