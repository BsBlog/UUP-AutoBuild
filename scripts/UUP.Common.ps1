$script:UupApiBase = 'https://api.uupdump.net'
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

function ConvertTo-UupFlag {
    param(
        [Parameter(Mandatory)]
        [bool]$Value
    )

    if ($Value) {
        return 1
    }

    return 0
}

function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $safeName = $Name
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safeName = $safeName.Replace([string]$char, '_')
    }

    return ($safeName -replace '\s+', '_')
}

function Get-UupRetryDelaySeconds {
    param(
        [Parameter(Mandatory)]
        [int]$Attempt
    )

    return [Math]::Min(90, [int]([Math]::Pow(2, $Attempt) * 3))
}

function Invoke-UupApiRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [int]$MaxRetries = 6
    )

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
            $payloadText = [string]$response.Content
            $payload = if ([string]::IsNullOrWhiteSpace($payloadText)) {
                @{}
            } else {
                $payloadText | ConvertFrom-Json -AsHashtable -Depth 100
            }

            $apiError = $null
            if ($payload.ContainsKey('response') -and
                $payload.response -is [hashtable] -and
                $payload.response.ContainsKey('error')) {
                $apiError = [string]$payload.response.error
            }

            if ($statusCode -ge 200 -and $statusCode -lt 300 -and [string]::IsNullOrWhiteSpace($apiError)) {
                return $payload
            }

            $retryable = $statusCode -in @(429, 500, 502, 503, 504) -or $apiError -in @(
                'USER_RATE_LIMITED',
                'WU_REQUEST_FAILED',
                'EMPTY_FILELIST',
                'NO_UPDATE_FOUND'
            )

            $reason = if ($apiError) { $apiError } else { "HTTP_$statusCode" }

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

function Get-UupApiResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [int]$MaxRetries = 6
    )

    $payload = Invoke-UupApiRequest -Uri $Uri -MaxRetries $MaxRetries

    if (-not $payload.ContainsKey('response')) {
        throw "Unexpected UUP API payload: missing response key."
    }

    return $payload.response
}

function New-UupConvertConfig {
    [CmdletBinding()]
    param(
        [bool]$AddUpdates = $true,
        [bool]$Cleanup = $true,
        [bool]$NetFx3 = $true,
        [bool]$EsdCompression = $true
    )

    $updates = ConvertTo-UupFlag -Value $AddUpdates
    $cleanupValue = ConvertTo-UupFlag -Value $Cleanup
    $netfx = ConvertTo-UupFlag -Value $NetFx3
    $esd = ConvertTo-UupFlag -Value $EsdCompression

    return @"
[convert-UUP]
AutoStart    =1
AddUpdates   =$updates
Cleanup      =$cleanupValue
ResetBase    =0
NetFx3       =$netfx
StartVirtual =0
wim2esd      =$esd
wim2swm      =0
SkipISO      =0
SkipWinRE    =0
LCUwinre     =0
LCUmsuExpand =0
UpdtBootFiles=0
ForceDism    =0
RefESD       =0
SkipLCUmsu   =0
SkipEdge     =0
AutoExit     =1
DisableUpdatingUpgrade=0
AddDrivers   =0
Drv_Source   =\Drivers

[Store_Apps]
SkipApps     =0
AppsLevel    =0
StubAppsFull =0
CustomList   =0

[create_virtual_editions]
vUseDism     =1
vAutoStart   =1
vDeleteSource=0
vPreserve    =0
vwim2esd     =$esd
vwim2swm     =0
vSkipISO     =0
vAutoEditions=
vSortEditions=
"@
}
