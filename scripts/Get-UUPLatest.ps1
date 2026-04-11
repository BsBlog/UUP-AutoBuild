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

function Get-UupBuildNumberFromTitle {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    $buildMatch = [regex]::Match($Title, '\d{4,5}\.\d+')
    if (-not $buildMatch.Success) {
        throw "Unable to determine build number from title: $Title"
    }

    return $buildMatch.Value
}

function Get-UupBuildMajorFromTitle {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    return [int]((Get-UupBuildNumberFromTitle -Title $Title).Split('.')[0])
}

function Get-UupWindowsProductFromTitle {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    $normalizedTitle = $Title.Trim()

    $clientMatch = [regex]::Match($normalizedTitle, 'Windows\s+(?<version>10|11)\b')
    if ($clientMatch.Success) {
        $clientVersion = $clientMatch.Groups['version'].Value
        return [ordered]@{
            displayName = "Windows $clientVersion"
            token       = "Windows$clientVersion"
        }
    }

    $serverMatch = [regex]::Match($normalizedTitle, 'Windows\s+Server(?:\s+(?<version>\d{4}))?\b')
    if ($serverMatch.Success) {
        $serverVersion = $serverMatch.Groups['version'].Value
        if ([string]::IsNullOrWhiteSpace($serverVersion)) {
            return [ordered]@{
                displayName = 'Windows Server'
                token       = 'WindowsServer'
            }
        }

        return [ordered]@{
            displayName = "Windows Server $serverVersion"
            token       = "WindowsServer$serverVersion"
        }
    }

    $majorBuild = Get-UupBuildMajorFromTitle -Title $normalizedTitle
    if ($majorBuild -ge 22000) {
        return [ordered]@{
            displayName = 'Windows 11'
            token       = 'Windows11'
        }
    }

    if ($majorBuild -ge 10000) {
        return [ordered]@{
            displayName = 'Windows 10'
            token       = 'Windows10'
        }
    }

    return [ordered]@{
        displayName = 'Windows'
        token       = 'Windows'
    }
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

function Test-UupKnownFallbackMatch {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    if ($Title -notmatch [regex]::Escape($Arch)) {
        return $false
    }

    if (-not (Test-UupBuildTitle -Title $Title -SearchTerm $SearchTerm)) {
        return $false
    }

    $majorBuild = Get-UupBuildMajorFromTitle -Title $Title
    $normalizedRing = $Ring.Trim().ToUpperInvariant()

    switch ($normalizedRing) {
        'RETAIL' {
            return ($Title -notmatch 'Insider Preview|Preview Update|Quality Update|Security Update') -and
                ($Title -match '^Windows (10|11), version|^Feature update to Windows')
        }
        'WIF' {
            return ($Title -match 'Insider Preview Feature Update') -and
                ($Title -notmatch 'Quality Update|Server') -and
                $majorBuild -ge 27000 -and $majorBuild -lt 29000
        }
        'WIS' {
            return ($Title -match 'Insider Preview Feature Update') -and
                ($Title -notmatch 'Quality Update|Server') -and
                $majorBuild -ge 26000 -and $majorBuild -lt 27000
        }
        'CANARY' {
            return ($Title -match 'Insider Preview') -and
                ($Title -notmatch 'Feature Update|Quality Update|Server') -and
                $majorBuild -ge 29000
        }
        default {
            return $false
        }
    }
}

function Get-UupFetchPageCandidate {
    $fetchUri = '{0}/fetchupd.php?arch={1}&ring={2}' -f `
        $script:UupBaseUrl, `
        [uri]::EscapeDataString($Arch), `
        [uri]::EscapeDataString($Ring.ToLowerInvariant())

    $fetchHtml = Get-UupWebContent -Uri $fetchUri -MaxRetries 4
    $anchorMatches = [regex]::Matches(
        $fetchHtml,
        '<a href="selectlang\.php\?id=(?<id>[0-9a-f\-]+)">\s*(?<title>.*?)\s*</a>',
        [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Singleline'
    )

    foreach ($anchorMatch in $anchorMatches) {
        $candidateTitle = ConvertFrom-UupHtmlText -Text $anchorMatch.Groups['title'].Value
        if ($candidateTitle -notmatch [regex]::Escape($Arch)) {
            continue
        }

        if (-not (Test-UupBuildTitle -Title $candidateTitle -SearchTerm $SearchTerm)) {
            continue
        }

        return [ordered]@{
            source      = 'fetchupd-html'
            updateId    = $anchorMatch.Groups['id'].Value
            updateTitle = $candidateTitle
            foundBuild  = Get-UupBuildNumberFromTitle -Title $candidateTitle
        }
    }

    throw "Could not find a valid update link on $fetchUri"
}

function Get-UupKnownFallbackCandidate {
    $knownUri = '{0}/known.php' -f $script:UupBaseUrl
    $knownHtml = Get-UupWebContent -Uri $knownUri -MaxRetries 3
    $anchorMatches = [regex]::Matches(
        $knownHtml,
        '<a href="selectlang\.php\?id=(?<id>[0-9a-f\-]+)">\s*(?<title>.*?)\s*</a>',
        [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Singleline'
    )

    $checked = 0
    foreach ($anchorMatch in $anchorMatches) {
        if ($checked -ge $MaxCandidates) {
            break
        }

        $checked++
        $candidateTitle = ConvertFrom-UupHtmlText -Text $anchorMatch.Groups['title'].Value
        if (-not (Test-UupKnownFallbackMatch -Title $candidateTitle)) {
            continue
        }

        return [ordered]@{
            source      = 'known-html'
            updateId    = $anchorMatch.Groups['id'].Value
            updateTitle = $candidateTitle
            foundBuild  = Get-UupBuildNumberFromTitle -Title $candidateTitle
        }
    }

    return $null
}

function Get-UupLanguageList {
    param(
        [Parameter(Mandatory)]
        [string]$UpdateId
    )

    $selectLangUri = '{0}/selectlang.php?id={1}' -f `
        $script:UupBaseUrl, `
        [uri]::EscapeDataString($UpdateId)

    $selectLangHtml = Get-UupWebContent -Uri $selectLangUri -MaxRetries 4
    $languageMatches = [regex]::Matches(
        $selectLangHtml,
        '<option value="(?<lang>[a-z0-9\-]+)"[^>]*>',
        [System.Text.RegularExpressions.RegexOptions]'IgnoreCase'
    )

    $languages = New-Object System.Collections.Generic.List[string]
    foreach ($languageMatch in $languageMatches) {
        $langCode = $languageMatch.Groups['lang'].Value.ToLowerInvariant()
        if ($langCode -match '^[a-z0-9\-]+$' -and -not $languages.Contains($langCode)) {
            $languages.Add($langCode)
        }
    }

    return @($languages)
}

function Test-UupEditionAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$UpdateId
    )

    $editionSlug = $Edition.ToLowerInvariant()
    $downloadUri = '{0}/download.php?id={1}&pack={2}&edition={3}' -f `
        $script:UupBaseUrl, `
        [uri]::EscapeDataString($UpdateId), `
        [uri]::EscapeDataString($Language), `
        [uri]::EscapeDataString($editionSlug)

    $downloadHtml = Get-UupWebContent -Uri $downloadUri -MaxRetries 4
    $expectedAction = 'get.php?id={0}&pack={1}&edition={2}' -f $UpdateId, $Language, $editionSlug

    return $downloadHtml -match [regex]::Escape($expectedAction)
}

Ensure-Directory -Path (Split-Path -Path $OutputPath -Parent) | Out-Null

$candidate = $null

try {
    Write-UupLog "Trying webpage fetch for $Ring / $Arch"
    $candidate = Get-UupFetchPageCandidate
    Write-UupLog "Selected fetch page candidate $($candidate.updateTitle)"
} catch {
    Write-Warning "Webpage fetch did not return a usable build: $($_.Exception.Message)"
}

if ($null -eq $candidate) {
    Write-UupLog "Falling back to known builds page for $Ring / $Arch"
    $candidate = Get-UupKnownFallbackCandidate
}

if ($null -eq $candidate) {
    throw "No suitable $Ring build found for $Arch using webpage parsing."
}

$availableLanguages = Get-UupLanguageList -UpdateId $candidate.updateId
if (-not ($availableLanguages -contains $Language.ToLowerInvariant())) {
    throw "Language $Language is not available for update $($candidate.updateId)"
}

if (-not (Test-UupEditionAvailable -UpdateId $candidate.updateId)) {
    throw "Edition $Edition is not available for update $($candidate.updateId) and language $Language"
}

$windowsProduct = Get-UupWindowsProductFromTitle -Title $candidate.updateTitle

$result = [ordered]@{
    source      = $candidate.source
    updateId    = $candidate.updateId
    updateTitle = $candidate.updateTitle
    foundBuild  = $candidate.foundBuild
    windowsDisplay = $windowsProduct.displayName
    windowsToken   = $windowsProduct.token
    arch        = $Arch
    ring        = $Ring
    flight      = $Flight
    sku         = $Sku
    language    = $Language
    edition     = $Edition
    searchTerm  = $SearchTerm
}

$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
