[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('smoke', 'state', 'status', 'set', 'params', 'programs', 'start', 'stop', 'delete', 'upload')]
    [string]$Command = 'smoke',

    [string]$BaseUrl = 'http://192.168.4.1',

    [ValidateRange(0, 1023)]
    [int]$Level = 0,

    [ValidateRange(0, 100)]
    [int]$BrightnessPct = 100,

    [ValidateRange(1.0, 3.0)]
    [double]$Gamma = 2.0,

    [ValidateSet('unchanged', 'on', 'off')]
    [string]$Loop = 'unchanged',

    [string]$Name,
    [string]$File,
    [switch]$Autorun,
    [ValidateRange(1, 120)]
    [int]$TimeoutSec = 5
)

$ErrorActionPreference = 'Stop'
$base = $BaseUrl.TrimEnd('/')

function Get-ApiJson([string]$Path) {
    Invoke-RestMethod -Uri "$base$Path" -Method Get -TimeoutSec $TimeoutSec
}

function Get-ApiText([string]$Path) {
    (Invoke-WebRequest -Uri "$base$Path" -Method Get -TimeoutSec $TimeoutSec).Content
}

function Send-ApiPost([string]$Path) {
    (Invoke-WebRequest -Uri "$base$Path" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec $TimeoutSec).Content
}

function Assert-ProgramName {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9_-]{1,48}$') {
        throw 'Specificare -Name con 1-48 caratteri ASCII: lettere, numeri, trattino o underscore.'
    }
}

function Show-State {
    Get-ApiJson '/api/state' | ConvertTo-Json -Depth 8
}

try {
    switch ($Command) {
        'smoke' {
            $state = Get-ApiJson '/api/state'
            $status = Get-ApiJson '/status'
            $programs = Get-ApiText '/prog/list'
            [pscustomobject]@{
                BaseUrl = $base
                On = $state.on
                Mode = $state.mode
                Level = $state.level
                BrightnessMaster = $state.brightnessMaster
                Gamma = $state.gamma
                Loop = $state.loop
                Ip = $status.ip
                Programs = $programs.Trim()
            } | Format-List
        }
        'state' {
            Show-State
        }
        'status' {
            Get-ApiJson '/status' | ConvertTo-Json -Depth 8
        }
        'set' {
            Get-ApiText "/set?y=$Level" | Out-Null
            Show-State
        }
        'params' {
            $query = [System.Collections.Generic.List[string]]::new()
            if ($PSBoundParameters.ContainsKey('BrightnessPct')) {
                $query.Add("brightness=$BrightnessPct")
            }
            if ($PSBoundParameters.ContainsKey('Gamma')) {
                $query.Add("gamma=$($Gamma.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))")
            }
            if ($Loop -ne 'unchanged') {
                $query.Add("loop=$(if ($Loop -eq 'on') { 1 } else { 0 })")
            }
            if ($query.Count -eq 0) {
                throw 'Specificare almeno uno tra -BrightnessPct, -Gamma o -Loop on|off.'
            }
            Get-ApiText "/params?$($query -join '&')" | Out-Null
            Show-State
        }
        'programs' {
            Get-ApiText '/prog/list'
        }
        'start' {
            Assert-ProgramName
            Send-ApiPost "/prog/start?name=$([Uri]::EscapeDataString($Name))"
        }
        'stop' {
            Send-ApiPost '/prog/stop'
        }
        'delete' {
            Assert-ProgramName
            (Invoke-WebRequest -Uri "$base/prog/delete?name=$([Uri]::EscapeDataString($Name))" -Method Delete -TimeoutSec $TimeoutSec).Content
        }
        'upload' {
            Assert-ProgramName
            if ([string]::IsNullOrWhiteSpace($File)) {
                throw 'Specificare -File con il percorso del programma .ldy.'
            }
            $resolvedFile = (Resolve-Path -LiteralPath $File).Path
            $autorunValue = if ($Autorun) { 1 } else { 0 }
            $uri = "$base/prog/save?name=$([Uri]::EscapeDataString($Name))&sr=0&autorun=$autorunValue"
            (Invoke-WebRequest -Uri $uri -Method Post -ContentType 'application/octet-stream' -InFile $resolvedFile -TimeoutSec $TimeoutSec).Content
        }
    }
} catch {
    throw "LightDome $Command fallito su $base`: $($_.Exception.Message)"
}
