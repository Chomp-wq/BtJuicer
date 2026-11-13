# The protection, tried in a real Brave on a throwaway Windows (CI): adult
# sites must load before it is on, so the test can tell, and must not after;
# Brave Search must be gone and Brave must have taken every rule. Turns the
# protection on for good: never run it on a PC you keep.

param([switch]$IKnowThisIsPermanent)
$ErrorActionPreference = 'Stop'
if (-not $IKnowThisIsPermanent -and $env:WINJUICER_PRUEBAS_REALES -ne '1') {
    throw 'Activa la protección para siempre: sólo en una máquina desechable (WINJUICER_PRUEBAS_REALES=1).'
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$brave = @(
    "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe"
    "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe"
    "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $brave) { throw 'Brave no está instalado.' }
Write-Host "Brave: $brave ($((Get-Item $brave).VersionInfo.ProductVersion))"

$work = Join-Path $env:RUNNER_TEMP 'brave-check'
New-Item -ItemType Directory -Force -Path $work | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'check.mjs') -Destination $work -Force
Push-Location $work
try {
    '{ "type": "module" }' | Set-Content -LiteralPath 'package.json' -Encoding ascii
    & npm install --no-save --no-audit --no-fund playwright-core@1.48.2 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'npm no pudo instalar playwright-core.' }

    function Invoke-Check([string]$Phase) {
        $json = & node check.mjs $brave $Phase
        if ($LASTEXITCODE -ne 0) { throw "La prueba de Brave falló ($Phase)." }
        $r = $json | ConvertFrom-Json
        foreach ($k in 'control', 'xvideos', 'pornhub', 'braveSearch') {
            $x = $r.$k
            Write-Host ('  {0,-8} {1,-12} {2}' -f $Phase, $k, $(if ($x.loaded) { "cargó: «$($x.title)» $($x.url)" } else { "no cargó: $($x.error)" }))
        }
        $r
    }
    # Loaded means the real site, not a block page or an error page.
    function Test-Adult($x) { $x.loaded -and ($x.title -match 'xvideos|pornhub|porn') }

    Write-Host 'Antes de activar la protección:'
    $before = Invoke-Check 'antes'
    if (-not $before.control.loaded) { throw 'Sin internet en el runner: la prueba no diría nada.' }
    $baseline = @('xvideos', 'pornhub' | Where-Object { Test-Adult $before.$_ })
    if ($baseline.Count -eq 0) { throw 'Ninguna web para adultos carga antes de activar la protección: la prueba no podría ver la diferencia.' }

    Write-Host 'Activando la protección (equilibrada, la más permisiva):'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'WinJuicer.ps1') -ProteccionAdultos Activar -NivelProteccion Equilibrado -Si | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "WinJuicer.ps1 -ProteccionAdultos Activar devolvió $LASTEXITCODE." }

    Write-Host 'Después:'
    $after = Invoke-Check 'despues'
    $fail = @()
    if (-not $after.control.loaded) { $fail += 'example.com ya no carga: la protección corta internet.' }
    foreach ($k in $baseline) { if (Test-Adult $after.$k) { $fail += "$k sigue cargando en Brave." } }
    if ($after.braveSearch.loaded -and $after.braveSearch.url -match 'search\.brave\.com') { $fail += 'Brave Search sigue cargando.' }
    Write-Host '--- brave://policy ---'
    Write-Host $after.policy
    foreach ($p in 'DnsOverHttpsMode', 'TorDisabled', 'BackgroundModeEnabled', 'ForceGoogleSafeSearch', 'DefaultSearchProviderSearchURL') {
        if ($after.policy -notmatch $p) { $fail += "Brave no muestra la regla $p." }
    }
    if ($after.policy -match '(?i)unknown policy|política desconocida') { $fail += 'Brave no reconoce alguna de las reglas.' }

    Write-Host 'Comprobación de Win Juicer:'
    $check = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'WinJuicer.ps1') -ProteccionAdultos Comprobar *>&1 | Out-String
    Write-Host $check
    if ($LASTEXITCODE -ne 0) { $fail += 'La comprobación de Win Juicer encontró problemas.' }
    if ($check -notmatch 'está bloqueada en este PC') { $fail += 'La comprobación de Win Juicer no confirmó el bloqueo con su prueba real.' }

    if ($fail.Count -gt 0) { $fail | ForEach-Object { Write-Host "FALLO: $_" }; exit 1 }
    Write-Host "Bien: $($baseline -join ' y ') cargaban antes y ya no; Brave Search bloqueado; Brave aplica las reglas."
} finally {
    Pop-Location
}
