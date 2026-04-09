[CmdletBinding()]
param(
    [string]$Arch = 'amd64',
    [Parameter(Mandatory)]
    [string]$Ring,
    [string]$Flight = 'Active',
    [int]$Sku = 48,
    [string]$Build = 'latest',
    [string]$Type = 'Production',
    [string]$SearchTerm = 'Windows',
    [Parameter(Mandatory)]
    [string]$Language,
    [string]$Edition = 'PROFESSIONAL',
    [Parameter(Mandatory)]
    [string]$OutputPath,
    [int]$MaxCandidates = 40
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/UUP.Common.ps1"

function Test-UupRingMatch {
    param(
        [Parameter(Mandatory)]
        [string]$RequestedRing,

        [Parameter(Mandatory)]
        [string]$ReturnedRing
    )

    $normalizedRequestedRing = $RequestedRing.Trim().ToUpperInvariant()
    $normalizedReturnedRing = $ReturnedRing.Trim().ToUpperInvariant()

    $acceptableReturnedRings = switch ($normalizedRequestedRing) {
        'CANARY' { @('CANARY', 'WIF') }
        default  { @($normalizedRequestedRing) }
    }

    return $acceptableReturnedRings -contains $normalizedReturnedRing
}

function Test-UupBuildTitle {
    param(
        [string]$Title,
        [string]$SearchTerm
    )

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return $false
    }

    $normalizedTitle = $Title.Trim()

    $excludePatterns = @(
        'Feature Experience Pack',
        '(^| )Preview Update',
        '(^| )Cumulative Update',
        '^Update for ',
        'Security Update',
        '\.NET Framework',
        'Hotpatch',
        'Microsoft Edge'
    )

    foreach ($pattern in $excludePatterns) {
        if ($normalizedTitle -match $pattern) {
            return $false
        }
    }

    $includePatterns = @(
        '^(Windows (10|11|Server))',
        '^Feature update to Windows'
    )

    $included = $false
    foreach ($pattern in $includePatterns) {
        if ($normalizedTitle -match $pattern) {
            $included = $true
            break
        }
    }

    if (-not $included) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($SearchTerm)) {
        return $true
    }

    return $normalizedTitle.ToLowerInvariant().Contains($SearchTerm.ToLowerInvariant())
}

function Resolve-UupCandidate {
    param(
        [Parameter(Mandatory)]
        [string]$UpdateId,

        [Parameter(Mandatory)]
        [string]$Source
    )

    $langUri = '{0}/listlangs.php?id={1}' -f $script:UupApiBase, [uri]::EscapeDataString($UpdateId)
    $langResponse = Get-UupApiResponse -Uri $langUri

    if (-not ($langResponse.langList -contains $Language)) {
        return $null
    }

    if (-not $langResponse.ContainsKey('updateInfo')) {
        return $null
    }

    $updateInfo = $langResponse.updateInfo
    $candidateTitle = [string]$updateInfo.title

    if (-not (Test-UupRingMatch -RequestedRing $Ring -ReturnedRing ([string]$updateInfo.ring))) {
        return $null
    }

    if (-not [string]::Equals([string]$updateInfo.arch, $Arch, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if (-not (Test-UupBuildTitle -Title $candidateTitle -SearchTerm $SearchTerm)) {
        return $null
    }

    $editionUri = '{0}/listeditions.php?id={1}&lang={2}' -f `
        $script:UupApiBase, `
        [uri]::EscapeDataString($UpdateId), `
        [uri]::EscapeDataString($Language)

    $editionResponse = Get-UupApiResponse -Uri $editionUri

    if (-not ($editionResponse.editionList -contains $Edition)) {
        return $null
    }

    return [ordered]@{
        source      = $Source
        updateId    = $UpdateId
        updateTitle = $candidateTitle
        foundBuild  = [string]$updateInfo.build
        arch        = [string]$updateInfo.arch
        ring        = [string]$updateInfo.ring
        flight      = [string]$updateInfo.flight
        sku         = [int]$updateInfo.sku
        language    = $Language
        edition     = $Edition
        searchTerm  = $SearchTerm
    }
}

Ensure-Directory -Path (Split-Path -Path $OutputPath -Parent) | Out-Null

$liveFetchUri = '{0}/fetchupd.php?arch={1}&ring={2}&flight={3}&build={4}&sku={5}&type={6}' -f `
    $script:UupApiBase, `
    [uri]::EscapeDataString($Arch), `
    [uri]::EscapeDataString($Ring), `
    [uri]::EscapeDataString($Flight), `
    [uri]::EscapeDataString($Build), `
    $Sku, `
    [uri]::EscapeDataString($Type)

try {
    Write-UupLog "Trying live fetch for $Ring / $Language"
    $liveResponse = Get-UupApiResponse -Uri $liveFetchUri -MaxRetries 2

    if ($liveResponse.ContainsKey('updateId')) {
        $candidate = Resolve-UupCandidate -UpdateId ([string]$liveResponse.updateId) -Source 'fetchupd'
        if ($null -ne $candidate) {
            $candidate | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
            Write-UupLog "Selected live candidate $($candidate.updateTitle)"
            return
        }
    }
} catch {
    Write-Warning "Live fetch did not return a usable build: $($_.Exception.Message)"
}

Write-UupLog "Falling back to listid search for $Ring / $Language"

$listUri = '{0}/listid.php?search={1}&sortByDate=1' -f `
    $script:UupApiBase, `
    [uri]::EscapeDataString($SearchTerm)

$listResponse = Get-UupApiResponse -Uri $listUri

$buildItems = @()
if ($listResponse.builds -is [hashtable]) {
    $buildItems = $listResponse.builds.GetEnumerator() |
        Sort-Object { [int]$_.Key } |
        ForEach-Object { $_.Value }
} else {
    $buildItems = @($listResponse.builds)
}

$checkedCandidates = 0

foreach ($buildItem in $buildItems) {
    if ($checkedCandidates -ge $MaxCandidates) {
        break
    }

    $checkedCandidates++
    $candidateTitle = [string]$buildItem.title
    $candidateArch = [string]$buildItem.arch

    if (-not [string]::Equals($candidateArch, $Arch, [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
    }

    if (-not (Test-UupBuildTitle -Title $candidateTitle -SearchTerm $SearchTerm)) {
        continue
    }

    try {
        $candidate = Resolve-UupCandidate -UpdateId ([string]$buildItem.uuid) -Source 'listid'
        if ($null -ne $candidate) {
            $candidate | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
            Write-UupLog "Selected fallback candidate $($candidate.updateTitle)"
            return
        }
    } catch {
        Write-Warning "Failed to inspect candidate ${candidateTitle}: $($_.Exception.Message)"
    }
}

throw "No suitable $Ring build found for $Language and edition $Edition."
