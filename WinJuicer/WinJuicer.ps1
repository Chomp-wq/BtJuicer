<#
.SYNOPSIS
    Win Juicer: exprime Windows 10 y 11 para juegos y cargas rápidas, sin humo y con vuelta atrás.

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

.PARAMETER ApuntarAjuste
    Apunta el undervolt u overclock que has aplicado (-AjusteCpu, -AjusteGpu,
    -HerramientaGpu) y lo comprueba en cada inicio de sesión: avisa si una
    actualización de BIOS lo borra, si la RAM cambia de velocidad o si hay
    errores WHEA o cuelgues del driver de la gráfica desde entonces.

.PARAMETER AjusteCpu
    Con -ApuntarAjuste, el undervolt u overclock del procesador, con tus palabras
    (por ejemplo «Curve Optimizer -30»).

.PARAMETER AjusteGpu
    Con -ApuntarAjuste, el undervolt u overclock de la gráfica, con tus palabras
    (por ejemplo «curva 900 mV, memoria +500»).

.PARAMETER HerramientaGpu
    Con -ApuntarAjuste, el programa con el que lo aplicaste: Afterburner,
    Adrenalin o Intel.

.PARAMETER OlvidarAjuste
    Borra el ajuste apuntado y deja de comprobarlo.

.PARAMETER MedirJuego
    Mide FPS y frametimes durante esos segundos (de 10 a 600), empezando 10
    segundos después para dar tiempo a volver al juego. Usa PresentMon de Intel.

.PARAMETER Juego
    Con -MedirJuego, el .exe que medir (por ejemplo cs2.exe). Sin él, el que
    más fotogramas presente. Con -ModoPrudente, los .exe a los que aplicarlo.

.PARAMETER Juegos
    Lista los juegos instalados que encuentra (Steam, Epic, GOG, Xbox, EA,
    Ubisoft, Battle.net, Riot…) con lo que tiene cada uno.

.PARAMETER OptimizarJuegos
    A todos esos juegos, el frame pacer al ritmo recomendado para tu monitor
    (o -Fps) y, si hay dos gráficas, la dedicada.

.PARAMETER Mantener
    Optimiza los juegos instalados desde la última vez y recalcula el frame
    pacer si ha cambiado el monitor o cómo lo usas. Es lo que hace la tarea de
    inicio de sesión de -MantenerJuegos.

.PARAMETER MantenerJuegos
    Activar: copia Win Juicer a Program Files (sólo administradores pueden
    cambiarlo) y crea una tarea que hace -Mantener al iniciar sesión.
    Desactivar: quita la tarea y la copia.

.PARAMETER LimitarFps
    Juegos (.exe, separados por comas) a los que poner el frame pacer: un
    ritmo de fotogramas que se aplica solo cada vez que se abren, con NVIDIA
    en el driver y si no con RivaTuner Statistics Server. Sin -Fps, el
    recomendado para tu monitor.

.PARAMETER CalibrarJuego
    Mide ese juego (.exe) con su frame pacer durante 60 segundos (o los de
    -MedirJuego), empezando a los 10, y ajusta su ritmo a lo que sostiene de
    verdad: lo baja si no llega, lo sube si le sobra margen.

.PARAMETER Prioridad
    Con -LimitarFps o -CalibrarJuego, qué pone primero el frame pacer en esos
    juegos: Fluidez (el ritmo más estable dentro de lo que el monitor enseña
    entero) o Latencia (al calibrar, si el juego da para el doble de los Hz o
    más, sube ahí sin sincronización vertical: menos latencia, con cortes de
    imagen; para juegos competitivos).

.PARAMETER MotorPacer
    Con qué marca el ritmo el frame pacer: Auto (el driver si hay NVIDIA),
    nvidia o rtss (RivaTuner, que admite décimas: con estrobo, el ritmo va
    justo por debajo del refresco real). Los juegos que ya lo tienen pasan al
    nuevo motor.

.PARAMETER ModoPrudente
    Activar o Desactivar el modo prudente de los juegos de -Juego (separados
    por comas): el frame pacer pone sólo el límite de FPS y deja la
    sincronización vertical y la cola de fotogramas como las ponga el juego.
    Para un juego que se congela o se cierra con la receta completa.

.PARAMETER RestaurarPerfilesNvidia
    Pone de nuevo la copia de los perfiles del driver de NVIDIA (nvdrsdb*.bin)
    que Win Juicer hizo antes de su primer cambio en ellos. Sustituye TODOS los
    ajustes de perfiles de NVIDIA (los de cada juego y los globales) por los de
    la copia: pregunta antes (con -Si, no). Después hay que reiniciar el
    servicio del driver de NVIDIA o, mejor, el equipo.

.PARAMETER Fps
    Con -LimitarFps, el ritmo (de 20 a 1000).

.PARAMETER ModoMonitor
    Cómo usas tu monitor, que su EDID no dice y decide el ritmo del frame pacer:
    Automatico, VRR, Estrobo (ELMB, DyAc… sin VRR), EstroboSync (ELMB Sync…)
    o Fijo. Se guarda para ese monitor; con -LimitarFps, se usa ya.

.PARAMETER PantallaOled
    Si tu monitor es OLED, cuando su nombre no lo delata: Si, No, o Auto para
    volver a decidirlo por el nombre. Se guarda para ese monitor y manda sobre
    el nombre.

.PARAMETER Lista
    Muestra todos los ajustes, con su nombre corto y su estado.

.PARAMETER Revisar
    Lista lo que Windows (una actualización de funciones, otro programa) ha
    deshecho de lo que Win Juicer aplicó: ajustes del diario cuyo estado real ya
    no es el aplicado. No cambia nada. Con -Si los vuelve a aplicar, con las
    mismas confirmaciones de siempre (los ajustes Extremo, con -AceptoRiesgos);
    con -Simular, dice qué cambiaría.

.PARAMETER RestaurarDiario
    Si el diario de cambios está dañado, lo aparta como diario.dañado.json y
    restaura diario.1.json, la copia del diario anterior que deja cada guardado.
    Si el diario actual se lee bien, pregunta antes (con -Si, no).

.PARAMETER Estado
    «Listo para jugar»: Modo juego, programación de GPU (HAGS), optimizaciones
    para juegos en ventana, Resizable BAR, plan de energía, batería y frecuencia
    del monitor, con una marca y el motivo en cada línea. No cambia nada.

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

.PARAMETER ProteccionAdultos
    Activar: bloquea el contenido para adultos en todo el equipo y cierra los
    atajos para saltárselo (DNS filtrado de CleanBrowsing, cortafuegos de
    Windows, navegadores y archivo hosts). Es para siempre: una vez activada,
    Win Juicer no la desactiva ni la baja de nivel, «Deshacer todo» no la toca
    y una tarea la repone si algo la cambia. Pide escribir ACTIVAR (o -Si).
    Subir: de equilibrada a estricta. Bloquear: las webs de -BloquearWeb, para
    siempre. Estado: dice si está activa. Comprobar: prueba de verdad si este
    PC está filtrado y dice por qué no, si no lo está (una VPN, un navegador
    abierto desde antes…). Mantener: lo que ejecuta su tarea.

.PARAMETER NivelProteccion
    Con -ProteccionAdultos Activar. Estricto (por defecto, el recomendado si es
    para dejar el porno): también proxies, VPN y Reddit, sin ventanas privadas
    y el DNS sólo al filtro. Equilibrado: las webs para adultos y los atajos
    más comunes.

.PARAMETER BloquearWeb
    Webs que bloquear para siempre con la protección activa, separadas por
    comas: X, Reddit, Tumblr o cualquier dominio (ejemplo.com).

.PARAMETER DeshacerTodo
    Deshace todos los cambios de Win Juicer.

.PARAMETER Exportar
    Guarda en un archivo JSON lo que Win Juicer ha cambiado en este equipo.

.PARAMETER Importar
    Aplica la configuración de un archivo exportado en otro equipo.

.PARAMETER Simular
    Muestra qué cambiaría, sin cambiar nada. Vale con -Recomendado, -Perfil,
    -Aplicar, -QuitarApps, -Dns, -Importar, -Revisar, -Deshacer y -DeshacerTodo;
    con cualquier otra acción que cambie algo, se niega antes de hacer nada
    (código de salida 2).

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
    .\WinJuicer.ps1 -Revisar -Si

.EXAMPLE
    .\WinJuicer.ps1 -Aplicar juegos.ventana,ui.menu -Si

.EXAMPLE
    .\WinJuicer.ps1 -ProteccionAdultos Bloquear -BloquearWeb Reddit,ejemplo.com
#>
[CmdletBinding()]
param(
    [switch]$Diagnostico,
    [string]$Informe,
    [switch]$Equipo,
    [switch]$Medir,
    [switch]$NuevaMedida,
    [switch]$ApuntarAjuste,
    [string]$AjusteCpu,
    [string]$AjusteGpu,
    [ValidateSet('', 'Afterburner', 'Adrenalin', 'Intel')][string]$HerramientaGpu = '',
    [switch]$OlvidarAjuste,
    [int]$MedirJuego,
    [string]$Juego,
    [string[]]$LimitarFps = @(),
    [string]$CalibrarJuego,
    [ValidateSet('Fluidez', 'Latencia')][string]$Prioridad,
    [ValidateSet('Auto', 'nvidia', 'rtss')][string]$MotorPacer,
    [ValidateSet('', 'Activar', 'Desactivar')][string]$ModoPrudente = '',
    [switch]$RestaurarPerfilesNvidia,
    [switch]$Juegos,
    [switch]$OptimizarJuegos,
    [switch]$Mantener,
    [ValidateSet('', 'Activar', 'Desactivar')][string]$MantenerJuegos = '',
    [ValidateSet('Activar', 'Subir', 'Bloquear', 'Mantener', 'Estado', 'Comprobar')][string]$ProteccionAdultos,
    [ValidateSet('Equilibrado', 'Estricto')][string]$NivelProteccion,
    [string[]]$BloquearWeb = @(),
    [int]$Fps,
    [ValidateSet('Automatico', 'VRR', 'Estrobo', 'EstroboSync', 'Fijo')][string]$ModoMonitor,
    [ValidateSet('Auto', 'Si', 'No')][string]$PantallaOled,
    [switch]$Lista,
    [switch]$Revisar,
    [switch]$RestaurarDiario,
    [switch]$Estado,
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

# One value as the Windows command line (CommandLineToArgvW, what powershell.exe -File parses)
# will read it back: in double quotes, a run of backslashes before a quote is doubled and the
# quote escaped, and a run before the closing quote is doubled too. Without that, a path ending
# in a backslash swallows the closing quote and a value with a quote splits in two.
function ConvertTo-JuicerCommandLineArgument {
    param([AllowEmptyString()][string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)\z', '$1$1')
    '"' + $escaped + '"'
}

if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Host 'Win Juicer sólo funciona en Windows.' -ForegroundColor Red
    exit 1
}

# Paths as the folder this window is in sees them: the elevated copy starts in System32,
# and .NET file calls never follow Set-Location.
foreach ($k in 'Informe', 'Exportar', 'Importar') {
    if ($PSBoundParameters.ContainsKey($k) -and $PSBoundParameters[$k]) {
        $PSBoundParameters[$k] = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$PSBoundParameters[$k])
    }
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
    $arguments += @('-File', (ConvertTo-JuicerCommandLineArgument $PSCommandPath))
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value) { $arguments += "-$($kv.Key)" }
        } else {
            $arguments += "-$($kv.Key)"
            $arguments += ConvertTo-JuicerCommandLineArgument (@($kv.Value) -join ',')
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
