# The catalog: every change Win Juicer knows how to make, with what it does,
# what it buys and what it costs, in plain words.
#
# Level 1 (Seguro)       costs nothing anyone would miss.
# Level 2 (Rendimiento)  costs battery, looks, or a feature some people use.
# Level 3 (Extremo)      weakens security or breaks features; asked one by one.
#
# Impact is about performance only and errs low: «Bajo» means small, not zero.
# Reboot: No, Explorador (restart Explorer), Sesion (sign out), Reinicio.

$script:LevelNames = @{ 1 = 'Seguro'; 2 = 'Rendimiento'; 3 = 'Extremo' }
$script:CategoryOrder = @('Reparación', 'Energía', 'Juegos', 'Interfaz', 'Segundo plano', 'Disco', 'Red', 'Seguridad')

# --- Power plans ---------------------------------------------------------

# Fixed GUID for our own plan, so running the tool twice never leaves two.
$script:JuicerPlan = '5f1c7a4e-3b2d-4e8a-9c61-7d0b2a9e4f13'
$script:UltimatePlan = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:HighPerfPlan = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:BestPerformanceMode = 'ded574b5-45a0-4f42-8737-46345c09c238'
$script:GuidPattern = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

function Get-JuicerActivePlan {
    $r = Invoke-JuicerNative 'powercfg.exe' @('/getactivescheme')
    if ($r.Code -eq 0 -and $r.Output -match $script:GuidPattern) { return $Matches[0].ToLowerInvariant() }
    throw "powercfg no devolvió el plan activo: $($r.Output)"
}

function Test-JuicerPlanExists {
    param([string]$Guid)
    $r = Invoke-JuicerNative 'powercfg.exe' @('/list')
    $r.Output -match [regex]::Escape($Guid)
}

function New-JuicerPlan {
    $r = Invoke-JuicerNative 'powercfg.exe' @('/duplicatescheme', $script:UltimatePlan, $script:JuicerPlan)
    if ($r.Code -ne 0) {
        $r = Invoke-JuicerNative 'powercfg.exe' @('/duplicatescheme', $script:HighPerfPlan, $script:JuicerPlan)
    }
    if ($r.Code -ne 0) { throw "powercfg no pudo crear el plan: $($r.Output)" }
    [void](Invoke-JuicerNative 'powercfg.exe' @('/changename', $script:JuicerPlan, 'Win Juicer',
            'Máximo rendimiento: procesador sin aparcar núcleos y sin ahorro de energía en PCIe, USB ni disco.'))
    # Ultimate already has most of these; setting them makes it true whatever
    # it was duplicated from. Only the AC side: on battery the base plan rules.
    $settings = @(
        @('54533251-82be-4824-96c1-47b60b740d00', '893dee8e-2bef-41e0-89c6-b55d0929964c', '100'), # minimum processor state
        @('54533251-82be-4824-96c1-47b60b740d00', '0cc5b647-c1df-4637-891a-dec35c318583', '100'), # core parking: min cores
        @('501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5', '0'),   # PCIe link state power management
        @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', '0'),   # USB selective suspend
        @('0012ee47-9041-4b5d-9b77-535fba8b1442', '6738e2c4-e8a5-4a42-b16a-e040e769756e', '0')    # turn off disk after: never
    )
    foreach ($s in $settings) {
        $r = Invoke-JuicerNative 'powercfg.exe' (@('/setacvalueindex', $script:JuicerPlan) + $s)
        if ($r.Code -ne 0) { Write-JuicerLog "powercfg no aceptó $($s -join ' '): $($r.Output)" }
    }
}

# --- Boot configuration ----------------------------------------------------

# bcdedit prints element names untranslated in every language, which is what
# makes reading them by name safe.
function Get-JuicerBcdValue {
    param([string]$Name)
    $r = Invoke-JuicerNative 'bcdedit.exe' @('/enum', '{current}')
    if ($r.Code -ne 0) { throw "bcdedit no pudo leer la configuración de arranque: $($r.Output)" }
    foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -match ('^\s*' + [regex]::Escape($Name) + '\s+(\S+)')) { return $Matches[1] }
    }
    $null
}

function Set-JuicerBcdValue {
    param([string]$Name, [string]$Value)
    Suspend-JuicerBitLocker
    $arguments = if ($null -eq $Value -or $Value -eq '') { @('/deletevalue', '{current}', $Name) } else { @('/set', '{current}', $Name, $Value) }
    $r = Invoke-JuicerNative 'bcdedit.exe' $arguments
    if ($r.Code -ne 0) { throw "bcdedit no aceptó el cambio de ${Name}: $($r.Output)" }
}

$script:BitLockerSuspended = $false

# BitLocker can treat a changed boot configuration as tampering and ask for
# the recovery key on the next start — on many laptops nobody knows they have
# one. Suspending protection for a single reboot is what Microsoft does
# itself before firmware updates.
function Suspend-JuicerBitLocker {
    if ($script:BitLockerSuspended -or (Get-JuicerBackend).Name -ne 'Windows') { return }
    try {
        $vol = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
    } catch {
        return
    }
    if (-not $vol) { return }
    $status = Invoke-CimMethod -InputObject $vol -MethodName GetProtectionStatus
    if ($status.ProtectionStatus -ne 1) { return }
    $r = Invoke-CimMethod -InputObject $vol -MethodName DisableKeyProtectors -Arguments @{ DisableCount = [uint32]1 }
    if ($r.ReturnValue -ne 0) {
        throw "BitLocker está activo y no se pudo suspender para el próximo reinicio (código $($r.ReturnValue)). No se ha tocado el arranque."
    }
    $script:BitLockerSuspended = $true
    Write-JuicerLog 'BitLocker suspendido durante un reinicio para cambiar la configuración de arranque.'
}

function ConvertTo-JuicerBcdBool {
    param([string]$Value)
    if ($Value -match '^(yes|s[ií]|ja|oui|true|on|1)$') { 'yes' } else { 'no' }
}

# --- Small predicates ------------------------------------------------------

function Test-JuicerRegAbsentOr {
    param($Current, $Value)
    $null -eq $Current -or ($Current.Kind -eq 'DWord' -and $Current.Value -eq $Value)
}

function Get-JuicerNetworkInterfaceKeys {
    $base = 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    foreach ($g in (Get-JuicerRegChildren $base)) {
        $p = "$base\$g"
        $dhcp = Read-JuicerReg $p 'DhcpIPAddress'
        $static = Read-JuicerReg $p 'IPAddress'
        $addresses = @()
        if ($dhcp) { $addresses += @($dhcp.Value) }
        if ($static) { $addresses += @($static.Value) }
        if (@($addresses | Where-Object { $_ -and $_ -ne '0.0.0.0' }).Count -gt 0) { $p }
    }
}

# --- The catalog -----------------------------------------------------------

$script:Catalog = $null

function Get-JuicerCatalog {
    if ($null -eq $script:Catalog) { $script:Catalog = @(New-JuicerCatalog) }
    $script:Catalog
}

function Find-JuicerTweak {
    param([string]$Id)
    foreach ($t in (Get-JuicerCatalog)) { if ($t.Id -eq $Id) { return $t } }
    $null
}

function Get-JuicerProfile {
    param([ValidateRange(1, 3)][int]$Level)
    @(Get-JuicerCatalog | Where-Object { $_.Level -le $Level })
}

function New-JuicerCatalog {
    $mm = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $fs = 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'
    $cdm = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $adv = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    # --- Reparación: undo what other "optimizers" got wrong ---------------

    @{
        Id = 'reparar.sysmain'; Category = 'Reparación'; Level = 1; Impact = 'Medio'; Reboot = 'No'
        Title = 'Reactivar SysMain (Superfetch)'
        What = 'Vuelve a poner en automático el servicio que precarga en memoria las aplicaciones que usas a menudo, si alguien lo desactivó.'
        Gain = 'Las apps y juegos que más usas abren antes. Desactivarlo es un consejo de la época de los discos duros que hoy sólo hace el equipo más lento.'
        Cost = 'Ninguno: la memoria que usa se libera al instante en cuanto otro programa la pide.'
        Actions = @(
            @{ Type = 'Service'; Name = 'SysMain'; Start = 'Automatic'; Ok = { param($c) $c.Start -in 'Automatic', 'AutomaticDelayed' } }
        )
    }
    @{
        Id = 'reparar.paginacion'; Category = 'Reparación'; Level = 1; Impact = 'Alto'; Reboot = 'Reinicio'
        Title = 'Restaurar el archivo de paginación'
        What = 'Si no hay ningún archivo de paginación, deja que Windows lo gestione. Si tienes uno configurado a mano, no lo toca.'
        Gain = 'Sin paginación, en cuanto la memoria comprometida llega al límite los juegos se cierran sin avisar aunque quede RAM libre: Windows no puede prometer memoria que no tiene dónde respaldar.'
        Cost = 'Ocupa espacio en disco, que Windows ajusta según haga falta.'
        Actions = @(
            @{
                Type = 'Registry'; Path = $mm; Name = 'PagingFiles'; Kind = 'MultiString'; Value = @('?:\pagefile.sys')
                Ok = { param($c) $c -and $c.Kind -eq 'MultiString' -and @($c.Value | Where-Object { $_ -match '\S' }).Count -gt 0 }
            }
        )
    }
    @{
        Id = 'reparar.trim'; Category = 'Reparación'; Level = 1; Impact = 'Alto'; Reboot = 'No'
        Title = 'Activar TRIM'
        What = 'Comprueba que Windows avisa al SSD de los bloques que ya no se usan.'
        Gain = 'Sin TRIM, un SSD se vuelve más lento al escribir a medida que se llena.'
        Cost = 'Ninguno.'
        Actions = @(
            @{ Type = 'Registry'; Path = $fs; Name = 'DisableDeleteNotification'; Value = 0; Ok = { param($c) Test-JuicerRegAbsentOr $c 0 } }
        )
    }
    @{
        Id = 'reparar.reloj'; Category = 'Reparación'; Level = 1; Impact = 'Medio'; Reboot = 'Reinicio'
        Title = 'Quitar el reloj de plataforma forzado (HPET)'
        What = 'Borra «useplatformclock» de la configuración de arranque si otro optimizador lo dejó puesto.'
        Gain = 'Forzar el HPET encarece cada lectura del reloj, y un juego hace miles por segundo: menos FPS y más latencia.'
        Cost = 'Ninguno: Windows vuelve a elegir el mejor reloj disponible. Si BitLocker está activo, se suspende durante un reinicio para que no pida la clave de recuperación.'
        Actions = @(
            @{
                Type = 'Custom'; Key = 'useplatformclock'; Label = 'Arranque: borrar useplatformclock'
                Test = { $null -eq (Get-JuicerBcdValue 'useplatformclock') }
                Capture = { @{ Value = (Get-JuicerBcdValue 'useplatformclock') } }
                Apply = { Set-JuicerBcdValue 'useplatformclock' $null }
                Restore = { param($s) if ($s.Value) { Set-JuicerBcdValue 'useplatformclock' (ConvertTo-JuicerBcdBool $s.Value) } }
            }
        )
    }
    @{
        Id = 'reparar.cache'; Category = 'Reparación'; Level = 1; Impact = 'Medio'; Reboot = 'Reinicio'
        Title = 'Desactivar LargeSystemCache'
        What = 'Devuelve a su valor normal la caché de sistema grande, pensada para servidores de archivos.'
        Gain = 'En un PC de escritorio esa caché le quita RAM a juegos y aplicaciones.'
        Cost = 'Ninguno en un equipo de escritorio.'
        Actions = @(
            @{ Type = 'Registry'; Path = $mm; Name = 'LargeSystemCache'; Value = 0; Ok = { param($c) Test-JuicerRegAbsentOr $c 0 } }
        )
    }
    @{
        Id = 'reparar.apagado'; Category = 'Reparación'; Level = 1; Impact = 'Medio'; Reboot = 'Reinicio'
        Title = 'No vaciar la paginación al apagar'
        What = 'Desactiva el borrado del archivo de paginación en cada apagado.'
        Gain = 'Ese borrado puede alargar el apagado varios minutos.'
        Cost = 'Si se activó adrede por seguridad, algo propio de equipos de empresa, mejor dejarlo.'
        Actions = @(
            @{ Type = 'Registry'; Path = $mm; Name = 'ClearPageFileAtShutdown'; Value = 0; Ok = { param($c) Test-JuicerRegAbsentOr $c 0 } }
        )
    }
    @{
        Id = 'reparar.tcp'; Category = 'Reparación'; Level = 1; Impact = 'Alto'; Reboot = 'No'
        Title = 'Reactivar el ajuste automático de TCP'
        What = 'Vuelve a «normal» el ajuste automático de la ventana de recepción de TCP.'
        Gain = 'Desactivado, las descargas grandes (Steam, actualizaciones) se quedan en una fracción de la velocidad de tu conexión.'
        Cost = 'Ninguno.'
        Actions = @(
            @{
                Type = 'Custom'; Key = 'autotuning'; Label = 'TCP: autotuninglevel=normal'
                Test = { (Get-NetTCPSetting -SettingName Internet -ErrorAction Stop).AutoTuningLevelLocal -eq 'Normal' }
                Capture = { @{ Level = [string](Get-NetTCPSetting -SettingName Internet -ErrorAction Stop).AutoTuningLevelLocal } }
                Apply = {
                    $r = Invoke-JuicerNative 'netsh.exe' @('interface', 'tcp', 'set', 'global', 'autotuninglevel=normal')
                    if ($r.Code -ne 0) { throw "netsh: $($r.Output)" }
                }
                Restore = {
                    param($s)
                    $r = Invoke-JuicerNative 'netsh.exe' @('interface', 'tcp', 'set', 'global', ('autotuninglevel=' + $s.Level.ToLowerInvariant()))
                    if ($r.Code -ne 0) { throw "netsh: $($r.Output)" }
                }
            }
        )
    }
    @{
        Id = 'reparar.update'; Category = 'Reparación'; Level = 1; Impact = 'Bajo'; Reboot = 'No'
        Title = 'Reactivar Windows Update'
        What = 'Pone el servicio de Windows Update en manual si estaba deshabilitado; Windows lo arranca cuando lo necesita.'
        Gain = 'Desactivarlo no da rendimiento: sólo deja el equipo sin parches de seguridad ni drivers. El modo juego ya impide que se instale nada mientras juegas.'
        Cost = 'Las actualizaciones vuelven a llegar.'
        Actions = @(
            @{ Type = 'Service'; Name = 'wuauserv'; Start = 'Manual'; Ok = { param($c) $c.Start -ne 'Disabled' } }
        )
    }

    # --- Energía ---------------------------------------------------------

    @{
        Id = 'energia.plan'; Category = 'Energía'; Level = 2; Impact = 'Medio'; Reboot = 'No'
        Title = 'Plan de energía «Win Juicer»'
        What = 'Crea un plan basado en «Máximo rendimiento» de Windows, con el procesador al 100 % como mínimo, sin aparcar núcleos y sin ahorro de energía en PCIe, USB ni disco, y lo activa.'
        Gain = 'Elimina las micropausas de despertar núcleos y enlaces dormidos: mejora sobre todo los mínimos de FPS (el 1 % más lento) y la latencia. En FPS medios, poco.'
        Cost = 'Más consumo y temperatura en reposo. En un portátil con batería, bastante menos autonomía.'
        Skip = { if (Test-JuicerModernStandby) { 'Este equipo usa Modern Standby y Windows sólo admite ahí el plan Equilibrado; usa «Modo de energía» en su lugar.' } }
        Actions = @(
            @{
                Type = 'Custom'; Key = 'plan'; Label = 'Plan de energía activo: Win Juicer'
                Test = { (Get-JuicerActivePlan) -eq $script:JuicerPlan }
                Capture = { @{ Previous = (Get-JuicerActivePlan); Existed = (Test-JuicerPlanExists $script:JuicerPlan) } }
                Apply = {
                    if (-not (Test-JuicerPlanExists $script:JuicerPlan)) { New-JuicerPlan }
                    $r = Invoke-JuicerNative 'powercfg.exe' @('/setactive', $script:JuicerPlan)
                    if ($r.Code -ne 0) { throw "powercfg no pudo activar el plan: $($r.Output)" }
                }
                Restore = {
                    param($s)
                    $r = Invoke-JuicerNative 'powercfg.exe' @('/setactive', $s.Previous)
                    if ($r.Code -ne 0) { throw "powercfg no pudo volver al plan anterior: $($r.Output)" }
                    if (-not $s.Existed -and $s.Previous -ne $script:JuicerPlan) {
                        [void](Invoke-JuicerNative 'powercfg.exe' @('/delete', $script:JuicerPlan))
                    }
                }
            }
        )
    }
    @{
        Id = 'energia.modo'; Category = 'Energía'; Level = 2; Impact = 'Medio'; Reboot = 'No'
        Title = 'Modo de energía: mejor rendimiento'
        What = 'Pone «Modo de energía» de Configuración en «Mejor rendimiento» para la alimentación actual. Aplícalo con el cargador conectado.'
        Gain = 'En equipos con Modern Standby es el único control de rendimiento que Windows respeta: sube los límites de potencia y la frecuencia del procesador.'
        Cost = 'Más consumo y más ruido de ventiladores.'
        Skip = { if (-not (Test-JuicerModernStandby)) { 'Sólo hace falta en equipos con Modern Standby; aquí lo cubre el plan de energía.' } }
        Actions = @(
            @{
                Type = 'Custom'; Key = 'overlay'; Label = 'Modo de energía: mejor rendimiento'
                Test = { Initialize-JuicerNative; [WinJuicer.Native]::GetPowerMode() -eq $script:BestPerformanceMode }
                Capture = { Initialize-JuicerNative; @{ Mode = [WinJuicer.Native]::GetPowerMode() } }
                Apply = { [WinJuicer.Native]::SetPowerMode($script:BestPerformanceMode) }
                Restore = { param($s) Initialize-JuicerNative; [WinJuicer.Native]::SetPowerMode($s.Mode) }
            }
        )
    }
    @{
        Id = 'energia.limitacion'; Category = 'Energía'; Level = 2; Impact = 'Bajo'; Reboot = 'Reinicio'
        Title = 'Desactivar la limitación de energía (Power Throttling)'
        What = 'Impide que Windows mande a núcleos de eficiencia y frecuencias bajas los programas que no tienen el foco.'
        Gain = 'Se nota si juegas con algo a la vista que no tiene el foco (OBS, Discord, un segundo monitor), sobre todo con procesadores Intel de núcleos P y E.'
        Cost = 'Más consumo; en portátil, menos batería.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Name = 'PowerThrottlingOff'; Value = 1 }
        )
    }
    @{
        Id = 'energia.inicio'; Category = 'Energía'; Level = 1; Impact = 'Medio'; Reboot = 'No'
        Title = 'Inicio rápido'
        What = 'Activa el inicio rápido de Windows y, si la hibernación estaba apagada, crea el archivo reducido que necesita.'
        Gain = 'Al encender después de «Apagar», el núcleo se restaura desde disco en lugar de arrancar de cero: suele ahorrar varios segundos.'
        Cost = 'Con arranque dual, Linux verá la partición de Windows como en uso. «Reiniciar» no lo usa nunca, que es lo que conviene tras instalar drivers.'
        Actions = @(
            @{
                Type = 'Custom'; Key = 'hibernate'; Label = 'Hibernación activada (archivo reducido si estaba apagada)'
                Test = { $h = Read-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'; $h -and $h.Value -eq 1 }
                Capture = {
                    $h = Read-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
                    @{ Enabled = [bool]($h -and $h.Value -eq 1) }
                }
                Apply = {
                    param($s)
                    $r = Invoke-JuicerNative 'powercfg.exe' @('/hibernate', 'on')
                    if ($r.Code -ne 0) { throw "powercfg no pudo activar la hibernación: $($r.Output)" }
                    # Nobody was using full hibernation, so the reduced file, about half the
                    # size, is all fast startup needs.
                    if (-not $s.Enabled) { [void](Invoke-JuicerNative 'powercfg.exe' @('/hibernate', '/type', 'reduced')) }
                }
                Restore = {
                    param($s)
                    if (-not $s.Enabled) {
                        # Back to the default full type first, or the next person to
                        # turn hibernation on would inherit the reduced file.
                        [void](Invoke-JuicerNative 'powercfg.exe' @('/hibernate', '/type', 'full'))
                        $r = Invoke-JuicerNative 'powercfg.exe' @('/hibernate', 'off')
                        if ($r.Code -ne 0) { throw "powercfg no pudo desactivar la hibernación: $($r.Output)" }
                    }
                }
            }
            @{ Type = 'Registry'; Path = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name = 'HiberbootEnabled'; Value = 1 }
        )
    }

    # --- Juegos ----------------------------------------------------------

    @{
        Id = 'juegos.modo'; Category = 'Juegos'; Level = 1; Impact = 'Bajo'; Reboot = 'No'
        Title = 'Modo juego'
        What = 'Comprueba que el modo juego de Windows está activado.'
        Gain = 'Windows prioriza el juego en primer plano y no instala drivers ni muestra avisos de reinicio mientras juegas.'
        Cost = 'Ninguno.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKCU\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Value = 1 }
            @{ Type = 'Registry'; Path = 'HKCU\Software\Microsoft\GameBar'; Name = 'AllowAutoGameMode'; Value = 1 }
        )
    }
    @{
        Id = 'juegos.hags'; Category = 'Juegos'; Level = 1; Impact = 'Bajo'; Reboot = 'Reinicio'
        Title = 'Programación de GPU acelerada por hardware'
        What = 'Deja que la propia tarjeta gráfica gestione su cola de trabajo en lugar del procesador.'
        Gain = 'Algo menos de carga en la CPU y de latencia. Es obligatoria para la generación de fotogramas de DLSS. Si tu GPU no la admite, Windows la ignora.'
        Cost = 'En algún juego concreto ha causado tirones; si te pasa, deshazla.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode'; Value = 2 }
        )
    }
    @{
        Id = 'juegos.ventana'; Category = 'Juegos'; Level = 1; Impact = 'Medio'; Reboot = 'No'
        Title = 'Optimizaciones para juegos en ventana'
        What = 'Hace que los juegos DirectX 10 y 11 en ventana o sin bordes usen el modelo de presentación moderno (flip).'
        Gain = 'Latencia de pantalla completa exclusiva, y acceso a VRR y HDR automático, sin perder el alt-tab instantáneo.'
        Cost = 'Ninguno conocido. Si un juego muy antiguo se porta mal, se puede excluir en Configuración > Pantalla > Gráficos.'
        Skip = { if ((Get-JuicerWindowsBuild) -lt 22621) { 'Necesita Windows 11 22H2 o posterior.' } }
        Actions = @(
            @{ Type = 'RegistryToken'; Path = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'; Name = 'DirectXUserGlobalSettings'; Token = 'SwapEffectUpgradeEnable'; Value = '1' }
        )
    }
    @{
        Id = 'juegos.grabacion'; Category = 'Juegos'; Level = 2; Impact = 'Medio'; Reboot = 'No'
        Title = 'Desactivar la grabación de Xbox Game Bar'
        What = 'Apaga la captura de Game Bar y la grabación continua de «lo que acaba de pasar».'
        Gain = 'La grabación en segundo plano codifica vídeo todo el tiempo que juegas: cuesta FPS aunque nunca guardes un clip.'
        Cost = 'Ya no podrás grabar ni capturar con Win+Alt+G o Win+Alt+R. Las capturas de NVIDIA, AMD u OBS no se ven afectadas.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKCU\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 }
            @{ Type = 'Registry'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0 }
            @{ Type = 'Registry'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled'; Value = 0 }
        )
    }
    @{
        Id = 'juegos.raton'; Category = 'Juegos'; Level = 2; Impact = 'Bajo'; Reboot = 'Sesion'
        Title = 'Desactivar la aceleración del ratón'
        What = 'Apaga «Mejorar la precisión del puntero».'
        Gain = 'El cursor recorre siempre lo mismo para el mismo gesto de la mano: puntería consistente. Muchos juegos leen el ratón en crudo y ya lo ignoran, pero no todos, ni sus menús.'
        Cost = 'En el escritorio puede que quieras subir un poco la velocidad del puntero.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKCU\Control Panel\Mouse'; Name = 'MouseSpeed'; Kind = 'String'; Value = '0' }
            @{ Type = 'Registry'; Path = 'HKCU\Control Panel\Mouse'; Name = 'MouseThreshold1'; Kind = 'String'; Value = '0' }
            @{ Type = 'Registry'; Path = 'HKCU\Control Panel\Mouse'; Name = 'MouseThreshold2'; Kind = 'String'; Value = '0' }
        )
    }
    @{
        Id = 'juegos.teclas'; Category = 'Juegos'; Level = 2; Impact = 'Bajo'; Reboot = 'Sesion'
        Title = 'Quitar los atajos de teclas especiales'
        What = 'Desactiva los atajos que abren Teclas especiales (Mayús cinco veces), Teclas filtro y Teclas de alternancia.'
        Gain = 'Se acabó que el juego se minimice porque pulsaste Mayús cinco veces seguidas.'
        Cost = 'Las funciones de accesibilidad siguen en Configuración; sólo desaparece el atajo de teclado.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKCU\Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Kind = 'String'; Value = '506' }
            @{ Type = 'Registry'; Path = 'HKCU\Control Panel\Accessibility\Keyboard Response'; Name = 'Flags'; Kind = 'String'; Value = '122' }
            @{ Type = 'Registry'; Path = 'HKCU\Control Panel\Accessibility\ToggleKeys'; Name = 'Flags'; Kind = 'String'; Value = '58' }
        )
    }
    @{
        Id = 'juegos.mmcss'; Category = 'Juegos'; Level = 1; Impact = 'Bajo'; Reboot = 'Reinicio'
        Title = 'Reserva multimedia para segundo plano'
        What = 'Baja del 20 % al 10 % la CPU que el planificador multimedia reserva a tareas de fondo, y quita su límite de red mientras suena audio.'
        Gain = 'Pequeña. Está aquí porque no cuesta nada, no porque haga milagros.'
        Cost = 'Ninguno.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'SystemResponsiveness'; Value = 10 }
            @{ Type = 'Registry'; Path = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'NetworkThrottlingIndex'; Value = 0xFFFFFFFFL }
        )
    }

    # --- Interfaz --------------------------------------------------------

    @{
        Id = 'ui.animaciones'; Category = 'Interfaz'; Level = 2; Impact = 'Medio'; Reboot = 'Sesion'
        Title = 'Quitar animaciones'
        What = 'Desactiva los efectos de animación de Windows, la animación al minimizar y maximizar, las de la barra de tareas, y acorta la espera de los submenús.'
        Gain = 'Ventanas y menús aparecen al instante. No da FPS: hace que Windows se sienta más rápido.'
        Cost = 'Estética.'
        Actions = @(
            @{ Type = 'Spi'; Get = 0x1042; Set = 0x1043; Value = $false; Label = 'Efectos de animación: desactivados' }
            @{ Type = 'Registry'; Path = 'HKCU\Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate'; Kind = 'String'; Value = '0' }
            @{ Type = 'Registry'; Path = $adv; Name = 'TaskbarAnimations'; Value = 0 }
            @{ Type = 'Registry'; Path = 'HKCU\Control Panel\Desktop'; Name = 'MenuShowDelay'; Kind = 'String'; Value = '100' }
        )
    }
    @{
        Id = 'ui.transparencia'; Category = 'Interfaz'; Level = 2; Impact = 'Bajo'; Reboot = 'No'
        Title = 'Quitar la transparencia'
        What = 'Desactiva los efectos de transparencia en la barra de tareas, el menú Inicio y las ventanas.'
        Gain = 'Algo menos de trabajo para la GPU en el escritorio; se nota en gráficas integradas.'
        Cost = 'Estética.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Value = 0 }
        )
    }
    @{
        Id = 'ui.menu'; Category = 'Interfaz'; Level = 2; Impact = 'Bajo'; Reboot = 'Explorador'
        Title = 'Menú contextual clásico'
        What = 'El clic derecho abre directamente el menú completo, sin pasar por «Mostrar más opciones».'
        Gain = 'El menú nuevo de Windows 11 tarda en aparecer cuando hay extensiones instaladas; el clásico es instantáneo y lo tiene todo a la vista.'
        Cost = 'Estética: vuelve el menú de Windows 10.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; Name = ''; Kind = 'String'; Value = '' }
        )
    }
    @{
        Id = 'ui.busqueda'; Category = 'Interfaz'; Level = 2; Impact = 'Medio'; Reboot = 'Explorador'
        Title = 'Búsqueda de Inicio sin resultados web'
        What = 'Quita las sugerencias de Bing de la búsqueda del menú Inicio.'
        Gain = 'La búsqueda deja de esperar a internet: resultados locales al instante.'
        Cost = 'No verás resultados web al buscar desde Inicio.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKCU\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 }
        )
    }
    @{
        Id = 'ui.widgets'; Category = 'Interfaz'; Level = 2; Impact = 'Bajo'; Reboot = 'Sesion'
        Title = 'Desactivar Widgets'
        What = 'Desactiva el panel de Widgets (noticias, tiempo) mediante directiva.'
        Gain = 'El panel mantiene un navegador incrustado en memoria: suele liberar entre 100 y 300 MB de RAM y algo de red.'
        Cost = 'Desaparece el panel. Configuración puede decir «Algunas opciones las administra tu organización»: es esta directiva, nada más.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Value = 0 }
        )
    }
    @{
        Id = 'ui.sugerencias'; Category = 'Interfaz'; Level = 1; Impact = 'Bajo'; Reboot = 'No'
        Title = 'Sin apps promocionadas ni sugerencias'
        What = 'Impide que Windows instale por su cuenta apps promocionadas y quita sugerencias y consejos de Inicio y Configuración.'
        Gain = 'Menos programas instalados sin pedirlos que luego arrancan en segundo plano.'
        Cost = 'Ninguno.'
        Actions = @(
            @{ Type = 'Registry'; Path = $cdm; Name = 'SilentInstalledAppsEnabled'; Value = 0 }
            @{ Type = 'Registry'; Path = $cdm; Name = 'PreInstalledAppsEnabled'; Value = 0 }
            @{ Type = 'Registry'; Path = $cdm; Name = 'OemPreInstalledAppsEnabled'; Value = 0 }
            @{ Type = 'Registry'; Path = $cdm; Name = 'SystemPaneSuggestionsEnabled'; Value = 0 }
            @{ Type = 'Registry'; Path = $cdm; Name = 'SoftLandingEnabled'; Value = 0 }
            @{ Type = 'Registry'; Path = $cdm; Name = 'SubscribedContent-338388Enabled'; Value = 0 }
            @{ Type = 'Registry'; Path = $cdm; Name = 'SubscribedContent-338389Enabled'; Value = 0 }
            @{ Type = 'Registry'; Path = $cdm; Name = 'SubscribedContent-353694Enabled'; Value = 0 }
            @{ Type = 'Registry'; Path = $cdm; Name = 'SubscribedContent-353696Enabled'; Value = 0 }
            @{ Type = 'Registry'; Path = $adv; Name = 'Start_IrisRecommendations'; Value = 0 }
            @{ Type = 'Registry'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Value = 0 }
        )
    }

    # --- Segundo plano ---------------------------------------------------

    @{
        Id = 'fondo.telemetria'; Category = 'Segundo plano'; Level = 1; Impact = 'Bajo'; Reboot = 'No'
        Title = 'Desactivar el servicio de telemetría'
        What = 'Deshabilita «Experiencias del usuario y telemetría asociadas» (DiagTrack).'
        Gain = 'Evita la recogida y el envío periódico de datos de diagnóstico. Poca ganancia, pero sin efectos secundarios en un equipo doméstico.'
        Cost = 'El programa Windows Insider lo necesita.'
        Actions = @(
            @{ Type = 'Service'; Name = 'DiagTrack'; Start = 'Disabled' }
        )
    }
    @{
        Id = 'fondo.apps'; Category = 'Segundo plano'; Level = 2; Impact = 'Bajo'; Reboot = 'Sesion'
        Title = 'Apps de la Tienda sin segundo plano'
        What = 'Impide que las apps de Microsoft Store sigan ejecutándose cuando las cierras.'
        Gain = 'Menos procesos y menos memoria ocupada sin que lo sepas.'
        Cost = 'Las apps de la Tienda que avisan con la ventana cerrada (Enlace Móvil, WhatsApp, Correo) no notificarán hasta que las abras. Los programas normales no se ven afectados.'
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; Name = 'GlobalUserDisabled'; Value = 1 }
            @{ Type = 'Registry'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BackgroundAppGlobalToggle'; Value = 0 }
        )
    }
    @{
        Id = 'fondo.recall'; Category = 'Segundo plano'; Level = 2; Impact = 'Bajo'; Reboot = 'Reinicio'
        Title = 'Desactivar las instantáneas de Recall'
        What = 'Impide que Recall guarde capturas periódicas de la pantalla en los PC Copilot+.'
        Gain = 'Recall captura y analiza la pantalla continuamente: disco y NPU o CPU ocupados mientras juegas.'
        Cost = 'Pierdes la búsqueda en el historial de Recall.'
        Skip = { if ((Get-JuicerWindowsBuild) -lt 26100) { 'Recall sólo existe en Windows 11 24H2 o posterior.' } }
        Actions = @(
            @{ Type = 'Registry'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Value = 1 }
        )
    }
    @{
        Id = 'fondo.indexado'; Category = 'Segundo plano'; Level = 3; Impact = 'Bajo'; Reboot = 'No'
        Title = 'Desactivar el indexado de búsqueda'
        What = 'Deshabilita Windows Search, el servicio que indexa archivos, correo y aplicaciones.'
        Gain = 'Sin indexador no hay lecturas de disco en segundo plano. Sólo se nota con disco duro mecánico: con SSD el indexador ya se frena solo mientras usas el equipo.'
        Cost = 'Buscar archivos desde el Explorador o Inicio se vuelve lento, y la búsqueda de Outlook deja de funcionar.'
        Actions = @(
            @{ Type = 'Service'; Name = 'WSearch'; Start = 'Disabled' }
        )
    }

    # --- Disco -----------------------------------------------------------

    @{
        Id = 'disco.nombres83'; Category = 'Disco'; Level = 2; Impact = 'Bajo'; Reboot = 'Reinicio'
        Title = 'No crear nombres cortos 8.3'
        What = 'NTFS deja de generar el nombre corto estilo MS-DOS (PROGRA~1) de cada archivo nuevo.'
        Gain = 'Crear archivos en carpetas con miles de ellos (cachés de shaders, juegos con muchos archivos pequeños) es más rápido.'
        Cost = 'Algún instalador de la época de Windows 98 puede fallar. Los nombres cortos que ya existen no se tocan.'
        Actions = @(
            @{ Type = 'Registry'; Path = $fs; Name = 'NtfsDisable8dot3NameCreation'; Value = 1 }
        )
    }
    @{
        Id = 'disco.ultimoacceso'; Category = 'Disco'; Level = 2; Impact = 'Bajo'; Reboot = 'Reinicio'
        Title = 'No registrar la fecha de último acceso'
        What = 'NTFS deja de escribir en disco cada vez que se lee un archivo.'
        Gain = 'Menos escrituras al cargar juegos con muchos archivos.'
        Cost = 'El Sensor de almacenamiento usa esa fecha para borrar descargas que no abres desde hace tiempo y dejará de acertar.'
        Actions = @(
            @{ Type = 'Registry'; Path = $fs; Name = 'NtfsDisableLastAccessUpdate'; Value = 0x80000001L }
        )
    }

    # --- Red -------------------------------------------------------------

    @{
        Id = 'red.nagle'; Category = 'Red'; Level = 2; Impact = 'Bajo'; Reboot = 'Reinicio'
        Title = 'Desactivar el algoritmo de Nagle'
        What = 'En cada adaptador de red con dirección IP, envía al momento los paquetes TCP pequeños en lugar de agruparlos, y confirma cada uno sin esperar.'
        Gain = 'Menos latencia en juegos que usan TCP, sobre todo MMO como World of Warcraft o Final Fantasy XIV. La mayoría de shooters usa UDP y no notará nada.'
        Cost = 'Unos pocos paquetes más por segundo en la red.'
        Actions = {
            foreach ($p in (Get-JuicerNetworkInterfaceKeys)) {
                @{ Type = 'Registry'; Path = $p; Name = 'TcpAckFrequency'; Value = 1 }
                @{ Type = 'Registry'; Path = $p; Name = 'TCPNoDelay'; Value = 1 }
            }
        }
    }

    # --- Seguridad: real gains, real costs --------------------------------

    @{
        Id = 'seguridad.integridad'; Category = 'Seguridad'; Level = 3; Impact = 'Alto'; Reboot = 'Reinicio'
        Title = 'Desactivar la integridad de memoria (HVCI)'
        What = 'Apaga la integridad de memoria de «Aislamiento del núcleo», que verifica cada driver dentro de una máquina virtual protegida.'
        Gain = 'Microsoft reconoce que cuesta rendimiento en juegos y propone desactivarla a quien priorice jugar. En pruebas publicadas, de casi nada a más de un 10 % según juego y procesador.'
        Cost = 'Un driver malicioso o vulnerable lo tiene más fácil para hacerse con el núcleo de Windows. Si algún juego o anti-trampas deja de abrir, deshazlo.'
        Skip = {
            $p = Read-JuicerReg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'HypervisorEnforcedCodeIntegrity'
            if ($p -and $p.Value -ne 0) { 'La impone una directiva de grupo; Win Juicer no toca directivas de empresa.' }
        }
        Actions = @(
            @{
                Type = 'Registry'; Path = 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
                Name = 'Enabled'; Value = 0; Ok = { param($c) Test-JuicerRegAbsentOr $c 0 }
            }
        )
    }
    @{
        Id = 'seguridad.hipervisor'; Category = 'Seguridad'; Level = 3; Impact = 'Medio'; Reboot = 'Reinicio'
        Title = 'No arrancar el hipervisor de Windows'
        What = 'Impide que el hipervisor se cargue al arrancar; sin él no funciona nada basado en virtualización (VBS).'
        Gain = 'Quita la capa de virtualización que se interpone entre Windows y el hardware: elimina el coste de VBS entero, incluido lo que apagar la integridad de memoria no quita.'
        Cost = 'Dejan de funcionar WSL 2, Hyper-V, Windows Sandbox, Docker Desktop y Credential Guard. Si BitLocker está activo, se suspende durante un reinicio para que no pida la clave de recuperación.'
        Actions = @(
            @{
                Type = 'Custom'; Key = 'hypervisorlaunchtype'; Label = 'Arranque: hypervisorlaunchtype off'
                Test = { (Get-JuicerBcdValue 'hypervisorlaunchtype') -eq 'Off' }
                Capture = { @{ Value = (Get-JuicerBcdValue 'hypervisorlaunchtype') } }
                Apply = { Set-JuicerBcdValue 'hypervisorlaunchtype' 'off' }
                Restore = {
                    param($s)
                    $v = $null
                    if ($s.Value) { $v = if ($s.Value -eq 'Off') { 'off' } else { 'auto' } }
                    Set-JuicerBcdValue 'hypervisorlaunchtype' $v
                }
            }
        )
    }
}

# --- What Win Juicer refuses to do -----------------------------------------
#
# Half of what "optimizers" do is placebo and the other half breaks something.
# These are the classics, and why they are not in the catalog.

function Get-JuicerMyths {
    @(
        @{ Title = 'Desactivar SysMain (Superfetch)'; Why = 'Precarga en RAM lo que usas a menudo, y en SSD también acelera la apertura de programas. La memoria que ocupa se libera al instante si otro programa la pide. Si otro optimizador lo apagó, Reparación lo devuelve.' }
        @{ Title = 'Quitar el archivo de paginación'; Why = 'Aunque tengas 32 GB, Windows no puede comprometer memoria que no tiene dónde respaldar: los juegos se cierran con RAM libre. Tampoco hay volcados de memoria tras un pantallazo azul.' }
        @{ Title = 'Apagar la compresión de memoria'; Why = 'Comprimir una página en RAM es mucho más rápido que escribirla a disco. Apagarla sólo hace que pagine antes.' }
        @{ Title = '«Liberar RAM» o vaciar la memoria en espera'; Why = 'La RAM libre es RAM desperdiciada: Windows usa la sobrante como caché y la cede al instante. Vaciarla obliga a leer de nuevo desde disco. Las herramientas que lo hacían corregían un fallo concreto de 2018 ya resuelto.' }
        @{ Title = 'Desactivar Microsoft Defender'; Why = 'Lo que Defender cuesta en juegos está en las cargas, y se resuelve con exclusiones de la carpeta de juegos (en Juegos), no apagando la protección de todo el equipo.' }
        @{ Title = 'Desactivar las mitigaciones de Spectre y Meltdown'; Why = 'En procesadores de 2019 en adelante la protección es por hardware y casi no cuesta nada; quitarla abre una vulnerabilidad real a cambio de nada medible.' }
        @{ Title = 'Desactivar Windows Update'; Why = 'No da rendimiento. Deja el equipo sin parches de seguridad ni drivers. El modo juego ya evita instalaciones y reinicios mientras juegas.' }
        @{ Title = 'Borrar la caché de shaders'; Why = 'La siguiente partida tendrá tirones mientras cada shader se vuelve a compilar. Sólo tiene sentido si un juego concreto falla y su soporte lo pide.' }
        @{ Title = 'Forzar el HPET con bcdedit'; Why = '«useplatformclock» hace más lento cada acceso al reloj, y los juegos lo leen miles de veces por segundo. Si otro programa lo dejó puesto, Reparación lo quita.' }
        @{ Title = 'Desactivar las optimizaciones de pantalla completa'; Why = 'En Windows 11, el modelo flip da la misma latencia que la pantalla completa exclusiva, con alt-tab instantáneo. Lo que sí activamos son las optimizaciones para juegos en ventana.' }
        @{ Title = 'Las claves «Games» de MMCSS (GPU Priority, Scheduling Category)'; Why = 'Sólo afectan a procesos que se registran en esa tarea del planificador multimedia, y casi ningún juego lo hace. Circulan en todas las guías sin una sola medición detrás.' }
        @{ Title = 'Win32PrioritySeparation y valores «mágicos» del planificador'; Why = 'Las cifras que circulan no vienen con mediciones. El planificador de Windows 11, con los procesadores híbridos, ya hace lo que esos valores pretenden.' }
        @{ Title = 'Limpiadores de registro'; Why = 'Un registro con claves de más no es más lento: Windows no lo lee entero. Borrar claves «sobrantes» sí puede romper programas.' }
        @{ Title = 'Desinstalar en bloque las apps preinstaladas'; Why = 'Si no se abren, no consumen nada. Lo que consume es lo que arranca solo, y eso lo controla Programas de inicio. Lo que sí hacemos es impedir que Windows instale más por su cuenta.' }
        @{ Title = 'Desactivar servicios en masa'; Why = 'Los servicios en manual no consumen nada hasta que algo los necesita. Desactivarlos en bloque rompe la impresora, el Bluetooth o la Tienda sin ganar nada medible. Sólo tocamos la telemetría y, en Extremo, el indexado.' }
        @{ Title = 'Apagar la hibernación «para ganar espacio»'; Why = 'Se lleva por delante el inicio rápido. Si la hibernación no se usa, Win Juicer la deja en el modo reducido, que ocupa la mitad.' }
        @{ Title = 'Cambiar de DNS «para bajar el ping»'; Why = 'El DNS sólo interviene al buscar la dirección del servidor, una vez al conectar. No toca ni un paquete de la partida.' }
        @{ Title = 'Desactivar el ahorro de energía de la tarjeta de red o la moderación de interrupciones'; Why = 'Gana microsegundos que no ve nadie y sube el uso de CPU. La latencia que notas está en internet, no en tu adaptador.' }
    )
}
