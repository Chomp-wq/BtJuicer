<#
.SYNOPSIS
    Win Juicer: exprime Windows 11 para juegos y cargas rápidas, sin humo y con vuelta atrás.

.DESCRIPTION
    Sin parámetros abre el menú. Cada cambio queda en un diario
    (%ProgramData%\WinJuicer\diario.json) con el estado anterior, de modo que
    cualquier ajuste se puede deshacer, uno a uno o todos a la vez.

.PARAMETER Diagnostico
    Revisa el equipo y dice qué lo frena. No cambia nada.

.PARAMETER Lista
    Muestra todos los ajustes, con su nombre corto y su estado.

.PARAMETER Perfil
    Seguro, Rendimiento o Extremo. Cada nivel incluye los anteriores.

.PARAMETER Aplicar
    Nombres cortos de ajustes concretos, separados por comas (ver -Lista).

.PARAMETER Deshacer
    Nombres de ajustes a devolver a su estado anterior.

.PARAMETER DeshacerTodo
    Deshace todos los cambios de Win Juicer.

.PARAMETER Simular
    Muestra qué cambiaría, sin cambiar nada.

.PARAMETER Si
    No pregunta. Los ajustes Extremo siguen necesitando -AceptoRiesgos.

.PARAMETER AceptoRiesgos
    Aplica los ajustes Extremo sin confirmarlos uno a uno.

.PARAMETER SinPuntoDeRestauracion
    No intenta crear un punto de restauración antes de aplicar.

.EXAMPLE
    .\WinJuicer.ps1 -Diagnostico

.EXAMPLE
    .\WinJuicer.ps1 -Perfil Rendimiento -Simular

.EXAMPLE
    .\WinJuicer.ps1 -Aplicar juegos.ventana,ui.menu -Si
#>
[CmdletBinding()]
param(
    [switch]$Diagnostico,
    [switch]$Lista,
    [ValidateSet('Seguro', 'Rendimiento', 'Extremo')][string]$Perfil,
    [string[]]$Aplicar = @(),
    [string[]]$Deshacer = @(),
    [switch]$DeshacerTodo,
    [switch]$Simular,
    [switch]$Si,
    [switch]$AceptoRiesgos,
    [switch]$SinPuntoDeRestauracion
)

$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Host 'Win Juicer sólo funciona en Windows.' -ForegroundColor Red
    exit 1
}

$principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Relaunch elevated with the same arguments and the same PowerShell.
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($PSBoundParameters.Count -gt 0) { $arguments += '-NoExit' }
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
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -Verb RunAs | Out-Null
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
