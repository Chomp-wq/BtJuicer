# The protection, tried in a real Brave on a throwaway Windows (CI): adult
# sites must load before it is on, so the test can tell, and must not after;
# searching from Brave must still work, through Brave Search's forced
# SafeSearch, and Brave must have taken every rule. Turns the protection on
# for good: never run it on a PC you keep.

param(
    [switch]$IKnowThisIsPermanent,
    # Cero: turned on with this version. Publicada: turned on with the version
    # people have, the published one, and then this one opened with Brave open
    # on a search, as whoever updates Win Juicer does.
    [ValidateSet('Cero', 'Publicada')][string]$Desde = 'Cero'
)
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
        foreach ($k in 'control', 'xvideos', 'pornhub', 'braveSearch', 'braveAdult') {
            $x = $r.$k
            Write-Host ('  {0,-8} {1,-12} {2}' -f $Phase, $k, $(if ($x.loaded) { "cargó: «$($x.title)» $($x.url)" } else { "no cargó: $($x.error) $($x.url) $($x.text)" }))
        }
        $a = $r.braveAdult
        if ($a.loaded) { Write-Host ('  {0,-8} {1,-12} captcha: {2}; enlaces: {3}; a webs para adultos: {4}' -f $Phase, 'braveAdult', $a.captcha, $a.links, (@($a.adult) -join ', ')) }
        $r
    }
    # Loaded means the real site, not a block page or an error page.
    function Test-Adult($x) { $x.loaded -and ($x.title -match 'xvideos|pornhub|porn') }

    function Show-BraveDns([string]$When) {
        foreach ($n in 'search.brave.com', 'forcesafe.search.brave.com', 'safe.search.brave.com') {
            foreach ($srv in @('', '185.228.168.10', '185.228.168.168')) {
                $p = @{ Name = $n; Type = 'A'; DnsOnly = $true; ErrorAction = 'Stop' }
                if ($srv) { $p.Server = $srv }
                $r = try { @(Resolve-DnsName @p | ForEach-Object { if ($_.Type -eq 'A') { [string]$_.IPAddress } elseif ($_.Type -eq 'CNAME') { "CNAME $($_.NameHost)" } }) -join ', ' } catch { "ERROR $($_.Exception.Message)" }
                Write-Host ('  {0,-8} {1,-28} vía {2,-16} {3}' -f $When, $n, $(if ($srv) { $srv } else { 'Windows' }), $r)
            }
        }
    }
    Write-Host '--- DNS de Brave Search antes ---'
    Show-BraveDns 'antes'

    Write-Host 'Antes de activar la protección:'
    $before = Invoke-Check 'antes'
    if (-not $before.control.loaded) { throw 'Sin internet en el runner: la prueba no diría nada.' }
    $baseline = @('xvideos', 'pornhub' | Where-Object { Test-Adult $before.$_ })
    if ($baseline.Count -eq 0) { throw 'Ninguna web para adultos carga antes de activar la protección: la prueba no podría ver la diferencia.' }

    $fail = @()
    $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
    if ($Desde -eq 'Publicada') {
        # The version people have: the release «irm …/winjuicer.ps1 | iex» downloads.
        $old = Join-Path $env:RUNNER_TEMP 'publicada'
        Invoke-WebRequest -Uri "https://github.com/$env:GITHUB_REPOSITORY/releases/download/winjuicer/WinJuicer.zip" -OutFile "$old.zip" -UseBasicParsing
        Expand-Archive -LiteralPath "$old.zip" -DestinationPath $old -Force
        Write-Host "Activando la protección con la versión publicada, $(Get-Content -LiteralPath (Join-Path $old 'version.txt')) (equilibrada):"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $old 'WinJuicer.ps1') -ProteccionAdultos Activar -NivelProteccion Equilibrado -Si | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "La versión publicada no pudo activar la protección ($LASTEXITCODE)." }
        Get-Content -LiteralPath $hosts | Select-String 'search\.brave\.com' | ForEach-Object { Write-Host "  hosts: $_" }
        # Its task between two rounds, as it almost always is on a PC.
        $task = 'Win Juicer - Protección contra contenido adulto'
        for ($i = 0; $i -lt 60 -and (Get-ScheduledTask -TaskName $task).State -eq 'Running'; $i++) { Start-Sleep -Seconds 2 }
        $since = Get-Date
        Write-Host 'Con Brave abierto en una búsqueda, se abre esta versión, como al actualizar Win Juicer:'
        $json = & node check.mjs $brave actualizar (Join-Path $root 'WinJuicer.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'La prueba de Brave falló (actualizar).' }
        $up = $json | ConvertFrom-Json
        foreach ($k in 'antes', 'despues', 'xvideos') {
            $x = $up.$k
            Write-Host ('  {0,-10} {1}' -f $k, $(if ($x.loaded) { "cargó: «$($x.title)» $($x.url)" } else { "no cargó: $($x.error) $($x.url)" }))
        }
        Write-Host "  esta versión se abrió: $($up.abrir); Brave Search, $($up.segundos) s después de abrirla"
        $ua = $up.braveAdult
        if ($ua.loaded) { Write-Host ('  braveAdult captcha: {0}; enlaces: {1}; a webs para adultos: {2}' -f $ua.captcha, $ua.links, (@($ua.adult) -join ', ')) }
        $info = Get-ScheduledTaskInfo -TaskName $task
        Write-Host "  tarea: corrió a las $($info.LastRunTime.ToString('T')), resultado $($info.LastTaskResult)"
        Get-Content -LiteralPath $hosts | Select-String 'search\.brave\.com' | ForEach-Object { Write-Host "  hosts: $_" }
        if ($info.LastRunTime -lt $since) { $fail += 'La tarea de la protección no corrió al abrir esta versión: el arreglo esperaría a su siguiente vuelta.' }
        if (-not ($up.despues.loaded -and $up.despues.url -match 'search\.brave\.com')) { $fail += "Con Brave abierto, Brave Search sigue sin cargar al abrir esta versión ($($up.despues.error))." }
        if ($ua.loaded -and -not $ua.captcha -and @($ua.adult).Count -gt 0) { $fail += "Al actualizar, Brave Search enseña webs para adultos: $(@($ua.adult) -join ', ')." }
        if ($baseline -contains 'xvideos' -and (Test-Adult $up.xvideos)) { $fail += 'Al actualizar, xvideos carga en el Brave abierto.' }
    } else {
        Write-Host 'Activando la protección (equilibrada, la más permisiva):'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'WinJuicer.ps1') -ProteccionAdultos Activar -NivelProteccion Equilibrado -Si | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "WinJuicer.ps1 -ProteccionAdultos Activar devolvió $LASTEXITCODE." }
    }

    Write-Host 'Después:'
    $after = Invoke-Check 'despues'
    if (-not $after.control.loaded) { $fail += 'example.com ya no carga: la protección corta internet.' }
    foreach ($k in $baseline) { if (Test-Adult $after.$k) { $fail += "$k sigue cargando en Brave." } }
    # Searching from Brave must work: Brave Search, through its forced SafeSearch.
    Write-Host '--- DNS de Brave Search después ---'
    Show-BraveDns 'despues'
    $safe = @(Resolve-DnsName forcesafe.search.brave.com -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress } | Sort-Object)
    $now = @(Resolve-DnsName search.brave.com -Type A -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress } | Sort-Object)
    Write-Host "  forcesafe.search.brave.com: $($safe -join ', ')"
    Write-Host "  search.brave.com ahora:      $($now -join ', ')"
    Get-Content -LiteralPath $hosts | Select-String 'search\.brave\.com' | ForEach-Object { Write-Host "  hosts: $_" }
    if ($safe.Count -eq 0) { $fail += 'forcesafe.search.brave.com no resuelve a través del filtro.' }
    elseif (($now -join ',') -ne ($safe -join ',')) { $fail += 'search.brave.com no apunta a la búsqueda segura de Brave.' }
    if (-not ($after.braveSearch.loaded -and $after.braveSearch.url -match 'search\.brave\.com')) { $fail += "Brave Search no carga después: buscar desde Brave no funcionaría ($($after.braveSearch.error))." }
    $ba = $after.braveAdult
    if ($ba.loaded -and -not $ba.captcha -and @($ba.adult).Count -gt 0) { $fail += "Brave Search enseña webs para adultos: $(@($ba.adult) -join ', ')." }
    if ($ba.loaded -and $ba.captcha) { Write-Host '  (Brave Search respondió con un captcha: no se pueden ver los resultados desde aquí.)' }
    Write-Host '--- brave://policy ---'
    Write-Host $after.policy
    # Each rule the protection sets, listed by Brave and taken: «Status OK».
    foreach ($p in 'DnsOverHttpsMode', 'TorDisabled', 'BackgroundModeEnabled', 'ForceGoogleSafeSearch', 'ForceYouTubeRestrict') {
        if ($after.policy -notmatch "\b$p\b") { $fail += "Brave no muestra la regla $p."; continue }
        if ($after.policy -notmatch "\b$p\b.{0,200}?Status OK") { $fail += "Brave no acepta la regla $p." }
    }
    if ($after.policy -match 'Status (Error|Warning)') { $fail += 'Brave rechaza o avisa de alguna regla (ver brave://policy arriba).' }

    Write-Host 'Comprobación de Win Juicer:'
    $check = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'WinJuicer.ps1') -ProteccionAdultos Comprobar *>&1 | Out-String
    Write-Host $check
    if ($LASTEXITCODE -ne 0) { $fail += 'La comprobación de Win Juicer encontró problemas.' }
    if ($check -notmatch 'está bloqueada en este PC') { $fail += 'La comprobación de Win Juicer no confirmó el bloqueo con su prueba real.' }

    if ($fail.Count -gt 0) { $fail | ForEach-Object { Write-Host "FALLO: $_" }; exit 1 }
    Write-Host "Bien: $($baseline -join ' y ') cargaban antes y ya no; Brave Search funciona, con su búsqueda segura; Brave aplica las reglas."
    if ($Desde -eq 'Publicada') { Write-Host "Y al actualizar desde la versión publicada, con Brave abierto: Brave Search cargó $($up.segundos) s después de abrir esta versión, sin cerrar Brave." }
} finally {
    Pop-Location
}
