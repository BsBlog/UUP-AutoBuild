$script:UupBaseUrl = 'https://uupdump.net'
$script:UupUserAgent = 'UUP-AutoBuild/1.0'

function Write-UupLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "[UUP] $Message"
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function ConvertFrom-UupHtmlText {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $decodedText = [System.Net.WebUtility]::HtmlDecode($Text)
    return ([regex]::Replace($decodedText, '\s+', ' ')).Trim()
}

function Get-UupRetryDelaySeconds {
    param(
        [Parameter(Mandatory)]
        [int]$Attempt
    )

    return [Math]::Min(90, [int]([Math]::Pow(2, $Attempt) * 3))
}

function Test-UupTransientWebPage {
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    $transientPatterns = @(
        'You are being rate limited',
        'Just a moment\.\.\.',
        'Enable JavaScript and cookies to continue'
    )

    foreach ($pattern in $transientPatterns) {
        if ($Content -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-UupWebCachePath {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $cacheRoot = Ensure-Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'UUP-Dump-WebCache')
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hashBytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Uri))
    } finally {
        $sha1.Dispose()
    }

    $hashString = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
    return (Join-Path $cacheRoot "$hashString.html")
}

function Get-UupWebContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [int]$MaxRetries = 6,

        [int]$CacheTtlMinutes = 30
    )

    $cachePath = Get-UupWebCachePath -Uri $Uri

    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        $cacheAgeMinutes = ((Get-Date) - (Get-Item -LiteralPath $cachePath).LastWriteTime).TotalMinutes
        if ($cacheAgeMinutes -lt $CacheTtlMinutes) {
            return (Get-Content -LiteralPath $cachePath -Raw)
        }
    }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $requestParams = @{
                Uri                = $Uri
                Method             = 'GET'
                Headers            = @{ 'User-Agent' = $script:UupUserAgent }
                TimeoutSec         = 180
                SkipHttpErrorCheck = $true
            }
            $response = Invoke-WebRequest @requestParams

            $statusCode = [int]$response.StatusCode
            $content = [string]$response.Content
            $isTransientPage = Test-UupTransientWebPage -Content $content

            if ($statusCode -ge 200 -and $statusCode -lt 300 -and -not $isTransientPage) {
                Set-Content -LiteralPath $cachePath -Value $content -Encoding UTF8
                return $content
            }

            $reason = if ($isTransientPage) { 'WEB_RATE_LIMITED' } else { "HTTP_$statusCode" }
            $retryable = $isTransientPage -or $statusCode -in @(429, 500, 502, 503, 504)

            if ($attempt -ge $MaxRetries -or -not $retryable) {
                throw "Request to $Uri failed: $reason"
            }

            $delay = Get-UupRetryDelaySeconds -Attempt $attempt
            Write-Warning "Request to $Uri failed: $reason. Retrying in $delay seconds."
            Start-Sleep -Seconds $delay
        } catch {
            if ($attempt -ge $MaxRetries) {
                throw
            }

            $delay = Get-UupRetryDelaySeconds -Attempt $attempt
            Write-Warning "Request to $Uri raised an exception: $($_.Exception.Message). Retrying in $delay seconds."
            Start-Sleep -Seconds $delay
        }
    }

    throw "Request to $Uri failed after $MaxRetries attempts."
}
