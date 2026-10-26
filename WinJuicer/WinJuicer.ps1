<#
.SYNOPSIS
    Win Juicer: exprime Windows 11 para juegos y cargas rápidas, sin humo y con vuelta atrás.

.DESCRIPTION
    Sin parámetros abre la ventana (con -Consola, el menú de texto). Cada cambio
    queda en un diario (%ProgramData%\WinJuicer\diario.json) con el estado
    anterior, de modo que cualquier ajuste se puede deshacer, uno a uno o todos
    a la vez.

.PARAMETER Diagnostico
    Revisa el equipo, BIOS y overclock incluidos, y dice qué lo frena. No cambia nada.

.PARAMETER Informe
    Hace el diagnóstico y lo guarda en un archivo de texto en esa ruta. No cambia nada.

.PARAMETER Equipo
    Muestra el hardware detectado y, para cada ajuste, si conviene a este equipo y por qué.

.PARAMETER Medir
    Mide el arranque, los procesos, los servicios, la memoria y el espacio libre
    y los compara con la primera medida (la que se toma sola antes de aplicar
    nada por primera vez).

.PARAMETER NuevaMedida
    Descarta la medida inicial y guarda la de ahora como punto de partida.

.PARAMETER MedirJuego
    Mide FPS y frametimes durante esos segundos (de 10 a 600), empezando 10
    segundos después para dar tiempo a volver al juego. Usa PresentMon de Intel.

.PARAMETER Juego
    Con -MedirJuego, el .exe que medir (por ejemplo cs2.exe). Sin él, el que
    más fotogramas presente.

.PARAMETER Lista
    Muestra todos los ajustes, con su nombre corto y su estado.

.PARAMETER Recomendado
    Aplica lo recomendado para este equipo según su hardware.

.PARAMETER Perfil
    Seguro, Rendimiento o Extremo. Cada nivel incluye los anteriores.

.PARAMETER Aplicar
    Nombres cortos de ajustes concretos, separados por comas (ver -Lista).

.PARAMETER QuitarApps
    Apps que quitar (debloat), por nombre de paquete: Microsoft.BingNews,Clipchamp.Clipchamp.

.PARAMETER Dns
    Servidor DNS para los adaptadores conectados: Automatico, Cloudflare,
    CloudflareMalware, CloudflareFamilia, Google, Quad9, AdGuard, AdGuardFamilia, OpenDNS.

.PARAMETER Instalar
    Programas que instalar con winget, por identificador: Valve.Steam,Discord.Discord.

.PARAMETER Deshacer
    Nombres de ajustes a devolver a su estado anterior.

.PARAMETER DeshacerTodo
    Deshace todos los cambios de Win Juicer.

.PARAMETER Exportar
    Guarda en un archivo JSON lo que Win Juicer ha cambiado en este equipo.

.PARAMETER Importar
    Aplica la configuración de un archivo exportado en otro equipo.

.PARAMETER Simular
    Muestra qué cambiaría, sin cambiar nada.

.PARAMETER Si
    No pregunta. Los ajustes Extremo siguen necesitando -AceptoRiesgos.

.PARAMETER AceptoRiesgos
    Aplica los ajustes Extremo sin confirmarlos uno a uno.

.PARAMETER SinPuntoDeRestauracion
    No intenta crear un punto de restauración antes de aplicar.

.PARAMETER Consola
    Sin otros parámetros: el menú de texto en lugar de la ventana.

.EXAMPLE
    .\WinJuicer.ps1 -Diagnostico

.EXAMPLE
    .\WinJuicer.ps1 -Perfil Rendimiento -Simular

.EXAMPLE
    .\WinJuicer.ps1 -Recomendado -Simular

.EXAMPLE
    .\WinJuicer.ps1 -Aplicar juegos.ventana,ui.menu -Si
#>
[CmdletBinding()]
param(
    [switch]$Diagnostico,
    [string]$Informe,
    [switch]$Equipo,
    [switch]$Medir,
    [switch]$NuevaMedida,
    [int]$MedirJuego,
    [string]$Juego,
    [switch]$Lista,
    [switch]$Recomendado,
    [ValidateSet('Seguro', 'Rendimiento', 'Extremo')][string]$Perfil,
    [string[]]$Aplicar = @(),
    [string[]]$QuitarApps = @(),
    [string]$Dns,
    [string[]]$Instalar = @(),
    [string[]]$Deshacer = @(),
    [switch]$DeshacerTodo,
    [string]$Exportar,
    [string]$Importar,
    [switch]$Simular,
    [switch]$Si,
    [switch]$AceptoRiesgos,
    [switch]$SinPuntoDeRestauracion,
    [switch]$Consola
)

$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Host 'Win Juicer sólo funciona en Windows.' -ForegroundColor Red
    exit 1
}

# The window is WPF, which only runs on a single-threaded apartment.
$window = -not $Consola -and @($PSBoundParameters.Keys | Where-Object { $_ -notin 'Consola', 'Verbose', 'Debug' }).Count -eq 0
$sta = [Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA
$principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
$admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -or ($window -and -not $sta)) {
    # Relaunch elevated with the same arguments and the same PowerShell.
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA')
    if ($PSBoundParameters.Count -gt 0 -and -not $window) { $arguments += '-NoExit' }
    $arguments += @('-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value) { $arguments += "-$($kv.Key)" }
        } else {
            $arguments += "-$($kv.Key)"
            $arguments += '"' + (@($kv.Value) -join ',') + '"'
        }
    }
    try {
        if ($admin) {
            Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments | Out-Null
        } else {
            Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -Verb RunAs | Out-Null
        }
        exit 0
    } catch {
        Write-Host 'Win Juicer necesita permisos de administrador para cambiar la configuración del sistema.' -ForegroundColor Red
        exit 1
    }
}

# Downloaded as a zip, every file carries the mark of the web; clearing it
# once saves a security prompt next time.
Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

try { $Host.UI.RawUI.WindowTitle = 'Win Juicer' } catch { Write-Verbose 'Sin título de ventana' }

Import-Module (Join-Path $PSScriptRoot 'WinJuicer.psm1') -Force
$code = [int]@(Start-Juicer @PSBoundParameters)[-1]
exit $code
