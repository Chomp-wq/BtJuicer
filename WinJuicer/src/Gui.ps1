# The window, in the spirit of Chris Titus' WinUtil: tabs, checkboxes,
# «recommended» buttons and toggles. It is only a front end: every change
# goes through the same engine and journal as the console, so everything done
# here can be undone there and the other way round.
#
# Anything slow (reading the hardware, the diagnosis, applying, listing apps)
# runs in a background runspace with its own copy of the module, and the
# window only draws what comes back. Long external jobs (winget, DISM, SFC)
# open their own console window.

$script:Gui = $null

# --- Pure pieces, testable without a screen ----------------------------------

$script:ResultMarks = @{
    Aplicado = '✓'; Deshecho = '↺'; YaEstaba = '='; Simulado = '…'; NoAplica = '–'; NadaQueDeshacer = '–'; Error = '✗'; NoSeMantuvo = '~'
}

function Format-JuicerResultsText {
    param([object[]]$Results)
    $notes = @{ YaEstaba = 'ya estaba así'; NoAplica = 'no aplica'; NadaQueDeshacer = 'nada que deshacer'; NoSeMantuvo = 'Windows no lo conservó' }
    $lines = New-Object System.Collections.ArrayList
    foreach ($r in $Results) {
        $line = '{0} {1}' -f $script:ResultMarks[[string]$r.Outcome], $r.Title
        if ($notes[[string]$r.Outcome]) { $line += " — $($notes[[string]$r.Outcome])" }
        [void]$lines.Add($line)
        if ($r.Message) { [void]$lines.Add("     $($r.Message)") }
        if ($r.Outcome -eq 'Simulado') { foreach ($c in @($r.Changes)) { [void]$lines.Add("     · $c") } }
    }
    $done = @($Results | Where-Object { $_.Outcome -in 'Aplicado', 'Deshecho', 'NoSeMantuvo' })
    foreach ($kind in 'Reinicio', 'Sesion', 'Explorador') {
        $need = @($done | Where-Object { $_.Reboot -eq $kind })
        if ($need.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add(('{0}: {1}.' -f $script:RebootLabels[$kind], (($need | ForEach-Object { $_.Title }) -join ', ')))
        }
    }
    $lines -join "`n"
}

# Categories into two columns of similar height.
function Split-JuicerColumns {
    param([object[]]$Groups)
    $cols = @(@(), @())
    $h = @(0, 0)
    foreach ($g in $Groups) {
        $i = if ($h[0] -le $h[1]) { 0 } else { 1 }
        $cols[$i] += , $g
        $h[$i] += 2 + @($g.Items).Count
    }
    , $cols
}

# Which catalog tweaks a selection button checks. Only what can still be
# applied: done or not-applicable ones stay unchecked.
function Get-JuicerSelection {
    param([string]$Mode, [object[]]$Tweaks, [hashtable]$States, [hashtable]$Advice)
    @(foreach ($t in $Tweaks) {
            $s = $States[$t.Id]
            if (-not ($s -and $s.State -in 'Pendiente', 'Parcial')) { continue }
            $take = switch ($Mode) {
                'Recomendado' { $Advice[$t.Id] -and $Advice[$t.Id].Verdict -eq 'Recomendado' -and $t.Level -ge 1 }
                'Seguro' { $t.Level -eq 1 }
                'Rendimiento' { $t.Level -ge 1 -and $t.Level -le 2 }
                'Extremo' { $t.Level -ge 1 }
                default { $false }
            }
            if ($take) { $t.Id }
        })
}

# --- The window ------------------------------------------------------------------

$script:GuiXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Win Juicer" Width="1220" Height="800" MinWidth="960" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#1B1B1F" Foreground="#E8E8E8"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#E8E8E8"/>
      <Setter Property="Background" Value="#33333C"/>
      <Setter Property="BorderBrush" Value="#46464F"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#F5B400"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#F5B400"/>
      <Setter Property="Foreground" Value="#1B1B1F"/>
      <Setter Property="BorderBrush" Value="#F5B400"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E8E8E8"/>
      <Setter Property="Margin" Value="2,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#2A2A31"/>
      <Setter Property="Foreground" Value="#E8E8E8"/>
      <Setter Property="BorderBrush" Value="#46464F"/>
      <Setter Property="Padding" Value="10,8"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#9A9AA5"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" Padding="16,9" Margin="0,0,2,0" CornerRadius="5,5,0,0">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#E8E8E8"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#26262C"/>
                <Setter Property="Foreground" Value="#F5B400"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Note" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9A9AA5"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="4,2,4,6"/>
    </Style>
    <Style x:Key="Head" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#F5B400"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Margin" Value="2,12,2,4"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="16,12,16,8" LastChildFill="True">
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Left" VerticalAlignment="Center">
        <TextBlock Text="WIN JUICER" FontSize="24" FontWeight="Bold" Foreground="#F5B400"/>
        <TextBlock Text="  exprime Windows, sin humo y con vuelta atrás" FontSize="14" Foreground="#9A9AA5" VerticalAlignment="Bottom" Margin="0,0,0,4"/>
      </StackPanel>
      <StackPanel x:Name="UpdatePanel" Orientation="Horizontal" DockPanel.Dock="Right" VerticalAlignment="Center" Visibility="Collapsed" Margin="16,0,0,0">
        <TextBlock x:Name="UpdateNote" Foreground="#F5B400" VerticalAlignment="Center"/>
        <Button x:Name="BtnUpdateCopy" Content="Copiar la orden" ToolTip="Cierra Win Juicer y pega la orden en PowerShell"/>
      </StackPanel>
      <TextBlock x:Name="HwLine" Foreground="#9A9AA5" TextAlignment="Right" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="24,0,0,0"/>
    </DockPanel>

    <TabControl x:Name="Tabs" Grid.Row="1" Margin="12,0,12,0" Background="#26262C" BorderThickness="0" Padding="0">

      <TabItem Header="Equipo" x:Name="TabEquipo">
        <Grid Margin="14,10,14,10">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Grid.Row="0">
            <Button x:Name="BtnAudit" Content="Analizar de nuevo" DockPanel.Dock="Right"/>
            <Button x:Name="BtnAuditSave" Content="Guardar informe" DockPanel.Dock="Right"/>
            <Button x:Name="BtnMeasureReset" Content="Nueva medida inicial" DockPanel.Dock="Right" ToolTip="Empieza la comparación desde ahora"/>
            <Button x:Name="BtnMeasure" Content="Medir antes y después" DockPanel.Dock="Right" ToolTip="Arranque, procesos, servicios, memoria y espacio, comparados con la primera medida"/>
            <Button x:Name="BtnAuditRecommended" Content="Aplicar lo recomendado para este equipo" Style="{StaticResource Accent}" DockPanel.Dock="Right"/>
            <TextBlock Style="{StaticResource Note}" VerticalAlignment="Center" Text="Diagnóstico completo: hardware, BIOS y microcódigo, overclock y estabilidad, gráfica, discos y red. No cambia nada. Lo que necesita la BIOS o un cable no lo arregla ningún programa: cada aviso dice dónde se arregla."/>
          </DockPanel>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="AuditPanel" Margin="0,6,8,0"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <TabItem Header="Ajustes" x:Name="TabAjustes">
        <Grid Margin="14,10,14,10">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="330"/></Grid.ColumnDefinitions>
          <WrapPanel Grid.Row="0" Grid.ColumnSpan="2" VerticalAlignment="Center">
            <TextBlock Text="Selección:" VerticalAlignment="Center" Margin="2,0,6,0" Foreground="#9A9AA5"/>
            <Button x:Name="BtnSelRecomendado" Content="Para este equipo" Style="{StaticResource Accent}"/>
            <Button x:Name="BtnSelSeguro" Content="Seguro"/>
            <Button x:Name="BtnSelRendimiento" Content="Rendimiento"/>
            <Button x:Name="BtnSelExtremo" Content="Extremo"/>
            <Button x:Name="BtnSelNinguno" Content="Ninguno"/>
            <TextBlock Text="   " />
            <Button x:Name="BtnSimulate" Content="Simular"/>
            <Button x:Name="BtnUndoSelected" Content="Deshacer seleccionados"/>
            <Button x:Name="BtnApply" Content="Aplicar seleccionados" Style="{StaticResource Accent}"/>
            <CheckBox x:Name="ChkRestorePoint" Content="Punto de restauración antes" IsChecked="True" Margin="10,0,0,0"/>
            <TextBlock Text="   " />
            <Button x:Name="BtnExport" Content="Exportar…"/>
            <Button x:Name="BtnImport" Content="Importar…"/>
          </WrapPanel>
          <TextBlock Grid.Row="1" Grid.ColumnSpan="2" Style="{StaticResource Note}"
                     Text="Pasa el ratón por encima de cada ajuste: qué hace, qué ganas, qué cuesta y si conviene a este equipo. ★ recomendado aquí · ✓ ya aplicado · – no aplica en este equipo. Todo se puede deshacer."/>
          <ScrollViewer Grid.Row="2" Grid.Column="0" VerticalScrollBarVisibility="Auto">
            <Grid Margin="0,0,10,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel x:Name="TweaksLeft" Grid.Column="0" Margin="0,0,12,0"/>
              <StackPanel x:Name="TweaksRight" Grid.Column="1"/>
            </Grid>
          </ScrollViewer>
          <Border Grid.Row="2" Grid.Column="1" Background="#1F1F25" CornerRadius="6" Padding="12,4,12,10">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <TextBlock Text="Preferencias" Style="{StaticResource Head}"/>
                <TextBlock Style="{StaticResource Note}" Text="Se aplican al marcar o desmarcar."/>
                <StackPanel x:Name="PrefPanel"/>
                <TextBlock Text="Plan de energía" Style="{StaticResource Head}"/>
                <TextBlock x:Name="PlanNote" Style="{StaticResource Note}"/>
                <WrapPanel>
                  <Button x:Name="BtnPlanAdd" Content="Añadir y activar"/>
                  <Button x:Name="BtnPlanRemove" Content="Quitar"/>
                </WrapPanel>
                <TextBlock Text="DNS" Style="{StaticResource Head}"/>
                <TextBlock x:Name="DnsNote" Style="{StaticResource Note}"/>
                <ComboBox x:Name="DnsCombo" Margin="3"/>
                <WrapPanel>
                  <Button x:Name="BtnDns" Content="Usar este DNS"/>
                  <Button x:Name="BtnDnsUndo" Content="Volver al que tenía"/>
                </WrapPanel>
              </StackPanel>
            </ScrollViewer>
          </Border>
        </Grid>
      </TabItem>

      <TabItem Header="Debloat" x:Name="TabDebloat">
        <Grid Margin="14,10,14,10">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <WrapPanel Grid.Row="0">
            <Button x:Name="BtnDebloatRecommended" Content="Seleccionar las seguras" Style="{StaticResource Accent}"/>
            <Button x:Name="BtnDebloatNone" Content="Ninguna"/>
            <Button x:Name="BtnDebloatRemove" Content="Quitar seleccionadas"/>
            <Button x:Name="BtnDebloatRefresh" Content="Volver a leer"/>
            <Button x:Name="BtnDebloatReinstall" Content="Reinstalar quitadas…"/>
          </WrapPanel>
          <TextBlock Grid.Row="1" Style="{StaticResource Note}" Text="Sólo aparecen las apps que están instaladas. Quitar una la desinstala para todos los usuarios; deshacer la reinstala desde Microsoft Store con winget. Una app cerrada no cuesta FPS: esto es espacio, actualizaciones en segundo plano y un menú Inicio limpio. «Necesaria aquí» marca lo que tu equipo usa."/>
          <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="DebloatPanel" Margin="0,0,8,0"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <TabItem Header="Instalar" x:Name="TabInstalar">
        <Grid Margin="14,10,14,10">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <WrapPanel Grid.Row="0">
            <TextBlock Text="Buscar:" VerticalAlignment="Center" Margin="2,0,6,0" Foreground="#9A9AA5"/>
            <TextBox x:Name="SearchBox" Width="220" Margin="3" Padding="4,3" Background="#33333C" Foreground="#E8E8E8" BorderBrush="#46464F"/>
            <Button x:Name="BtnInstallSuggested" Content="Sugeridos para este equipo"/>
            <Button x:Name="BtnInstallNone" Content="Ninguno"/>
            <Button x:Name="BtnInstall" Content="Instalar seleccionados" Style="{StaticResource Accent}"/>
            <Button x:Name="BtnUninstall" Content="Desinstalar seleccionados"/>
            <Button x:Name="BtnUpgradeAll" Content="Actualizar todo"/>
            <Button x:Name="BtnInstalledRefresh" Content="Ver lo instalado"/>
          </WrapPanel>
          <TextBlock x:Name="InstallNote" Grid.Row="1" Style="{StaticResource Note}" Text="Con winget, en su propia ventana para que veas el progreso. ✓ ya instalado · ★ sugerido para este equipo."/>
          <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
            <WrapPanel x:Name="AppsPanel" Margin="0,0,8,0"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <TabItem Header="Inicio" x:Name="TabInicio">
        <Grid Margin="14,10,14,10">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Grid.Row="0">
            <Button x:Name="BtnStartupRefresh" Content="Volver a leer" DockPanel.Dock="Right"/>
            <Button x:Name="BtnStartupJunk" Content="Desactivar los prescindibles" Style="{StaticResource Accent}" DockPanel.Dock="Right"/>
            <TextBlock Style="{StaticResource Note}" VerticalAlignment="Center" Text="Lo que arranca solo al iniciar sesión. Desmarcar no borra nada: es el mismo interruptor del Administrador de tareas, y se aplica al momento. Prescindible: funciona igual abriéndolo cuando lo necesites."/>
          </DockPanel>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="StartupPanel" Margin="0,4,8,0"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <TabItem Header="Juegos" x:Name="TabJuegos">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="14,4,14,10">
            <TextBlock Text="Tus juegos" Style="{StaticResource Head}"/>
            <TextBlock x:Name="GamesNote" Style="{StaticResource Note}" Text="Buscando los juegos de Steam, Epic, GOG, Xbox, EA, Ubisoft, Battle.net, Riot…"/>
            <WrapPanel>
              <Button x:Name="BtnGamesOptimize" Content="Optimizar los marcados" Style="{StaticResource Accent}" ToolTip="El límite de FPS recomendado para tu monitor (con la receta de baja latencia en NVIDIA) y, si tienes dos gráficas, la dedicada"/>
              <Button x:Name="BtnGamesLimit" Content="Sólo límite de FPS"/>
              <TextBox x:Name="LimitFps" Width="60" Margin="3" VerticalContentAlignment="Center" ToolTip="Déjalo vacío para usar el límite recomendado"/>
              <TextBlock Text="FPS (vacío: el recomendado)" VerticalAlignment="Center" Foreground="#9A9AA5" Margin="0,0,8,0"/>
              <Button x:Name="BtnGamesGpu" Content="GPU dedicada"/>
              <Button x:Name="BtnGamesPrio" Content="Prioridad alta"/>
              <Button x:Name="BtnGamesClear" Content="Quitar lo de Win Juicer"/>
            </WrapPanel>
            <WrapPanel>
              <Button x:Name="BtnGamesAll" Content="Marcar todos"/>
              <Button x:Name="BtnGamesNone" Content="Ninguno"/>
              <Button x:Name="BtnGamesAdd" Content="Añadir otro juego (.exe)…"/>
              <Button x:Name="BtnGamesRefresh" Content="Volver a buscar"/>
            </WrapPanel>
            <StackPanel x:Name="GamesPanel" Margin="0,4,0,0"/>
            <TextBlock Text="Limitador de FPS" Style="{StaticResource Head}"/>
            <TextBlock x:Name="LimitNote" Style="{StaticResource Note}" Text="Un límite por juego que se aplica solo cada vez que lo abres, sin inyectar nada en el juego (los anti-trampas no tienen nada que objetar)."/>
            <WrapPanel>
              <TextBlock Text="Cómo usas tu monitor:" VerticalAlignment="Center" Margin="4,0,6,0" Foreground="#9A9AA5"/>
              <ComboBox x:Name="MonitorMode" Width="430" Margin="3" ToolTip="El monitor no dice si tienes ELMB, DyAc o similar encendido: dilo aquí y el límite se ajusta"/>
              <Button x:Name="BtnLimitRecalc" Content="Recalcular los límites"/>
            </WrapPanel>
            <TextBlock Text="Medir FPS y frametimes" Style="{StaticResource Head}"/>
            <TextBlock Style="{StaticResource Note}" Text="Con PresentMon de Intel (se descarga la primera vez). Pulsa, vuelve al juego en 10 segundos y juega una escena que puedas repetir: media, 1 % y 0,1 % bajos, tirones, si limita el procesador o la gráfica y qué gastaba CPU en segundo plano. Cada medida se compara con la anterior del mismo juego, así sabes si un ajuste dio FPS de verdad."/>
            <WrapPanel>
              <ComboBox x:Name="FrameSeconds" Width="130" Margin="3" SelectedIndex="1">
                <ComboBoxItem Content="30 segundos" Tag="30"/>
                <ComboBoxItem Content="60 segundos" Tag="60"/>
                <ComboBoxItem Content="120 segundos" Tag="120"/>
              </ComboBox>
              <Button x:Name="BtnFrameMeasure" Content="Medir (empieza en 10 s)" Style="{StaticResource Accent}"/>
            </WrapPanel>
            <StackPanel x:Name="FramePanel"/>
            <TextBlock Text="Exclusiones de Microsoft Defender (nivel Extremo)" Style="{StaticResource Head}"/>
            <TextBlock Style="{StaticResource Note}" Text="Lo que más acorta las cargas de todo lo que Win Juicer puede tocar: Defender deja de analizar los archivos de esas carpetas al abrirse. A cambio, un archivo malicioso dentro de ellas no se detectaría al abrirse. Las tiendas verifican lo que descargan; los mods y lo que copies a mano, no."/>
            <StackPanel x:Name="LibPanel"/>
            <WrapPanel>
              <Button x:Name="BtnLibAdd" Content="Excluir las seleccionadas"/>
              <Button x:Name="BtnLibFolder" Content="Añadir otra carpeta…"/>
              <Button x:Name="BtnLibRefresh" Content="Volver a buscar"/>
            </WrapPanel>
            <TextBlock Style="{StaticResource Note}" Margin="4,12,4,4" Text="Lo que configures aquí se deshace en la pestaña Deshacer, como todo lo demás."/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Ajuste fino" x:Name="TabAjusteFino">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="14,4,14,10">
            <TextBlock Text="Undervolt y overclock para tu equipo" Style="{StaticResource Head}"/>
            <TextBlock Style="{StaticResource Note}" Text="El del procesador va en la BIOS: la placa lo guarda y lo aplica en cada arranque sin ningún programa, y Win Juicer no instala drivers de núcleo para tocarlo desde Windows (Defender los marca como vulnerables y los anti-trampas los vigilan). El de la gráfica, en su herramienta (Afterburner, AMD Software o Intel), que lo aplica al iniciar. Aquí tienes los valores de partida para tus componentes."/>
            <StackPanel x:Name="FineGuidePanel"/>
            <TextBlock Text="Lo que has aplicado" Style="{StaticResource Head}"/>
            <TextBlock Style="{StaticResource Note}" Text="Apúntalo y Win Juicer lo recordará: en cada inicio de sesión comprueba que una actualización de BIOS no lo ha borrado, que la RAM sigue a su velocidad y que no hay errores ni cuelgues desde entonces, y te avisa si algo cambia."/>
            <Grid Margin="0,4,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <TextBlock Grid.Row="0" Text="Procesador (BIOS)" VerticalAlignment="Center" Foreground="#9A9AA5"/>
              <TextBox Grid.Row="0" Grid.Column="1" x:Name="FineCpu" Margin="3" ToolTip="Por ejemplo: Curve Optimizer -30, o offset -40 mV"/>
              <TextBlock Grid.Row="1" Text="Gráfica" VerticalAlignment="Center" Foreground="#9A9AA5"/>
              <TextBox Grid.Row="1" Grid.Column="1" x:Name="FineGpu" Margin="3" ToolTip="Por ejemplo: curva 900 mV a 1900 MHz, memoria +500"/>
              <TextBlock Grid.Row="2" Text="La aplica" VerticalAlignment="Center" Foreground="#9A9AA5"/>
              <ComboBox Grid.Row="2" Grid.Column="1" x:Name="FineGpuTool" Margin="3" Width="220" HorizontalAlignment="Left" SelectedIndex="0">
                <ComboBoxItem Content="Nada / no lo sé" Tag=""/>
                <ComboBoxItem Content="MSI Afterburner" Tag="Afterburner"/>
                <ComboBoxItem Content="AMD Software (Adrenalin)" Tag="Adrenalin"/>
                <ComboBoxItem Content="Intel Graphics Software" Tag="Intel"/>
              </ComboBox>
            </Grid>
            <CheckBox x:Name="FineWatch" Content="Comprobarlo cada vez que inicio sesión y avisarme" IsChecked="True"/>
            <WrapPanel>
              <Button x:Name="BtnFineSave" Content="Apuntar mi ajuste" Style="{StaticResource Accent}"/>
              <Button x:Name="BtnFineForget" Content="Olvidarlo"/>
            </WrapPanel>
            <StackPanel x:Name="FineCheckPanel"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Mantenimiento" x:Name="TabMantenimiento">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="14,4,14,10">
            <TextBlock Text="Limpieza y reparación" Style="{StaticResource Head}"/>
            <TextBlock Style="{StaticResource Note}" Text="Cada tarea se abre en su propia ventana. No se pueden deshacer, por eso sólo borran lo que Windows regenera. La caché de shaders y Prefetch no se tocan: vaciarlas hace que la próxima partida tenga tirones."/>
            <WrapPanel>
              <Button x:Name="BtnCleanup" Content="Limpiar temporales"/>
              <Button x:Name="BtnOptimize" Content="Optimizar unidades (TRIM)"/>
              <Button x:Name="BtnComponents" Content="Limpiar componentes (WinSxS)"/>
              <Button x:Name="BtnRepair" Content="Reparar Windows (DISM + SFC)"/>
              <Button x:Name="BtnNetReset" Content="Restablecer la red"/>
              <Button x:Name="BtnWuReset" Content="Restablecer Windows Update"/>
              <Button x:Name="BtnRestorePoint" Content="Crear punto de restauración"/>
            </WrapPanel>
            <TextBlock Text="Componentes de Windows" Style="{StaticResource Head}"/>
            <TextBlock Style="{StaticResource Note}" Text="Se activan o desactivan al marcar; algunos piden reiniciar."/>
            <StackPanel x:Name="CompPanel"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Deshacer" x:Name="TabDeshacer">
        <Grid Margin="14,10,14,10">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <WrapPanel Grid.Row="0">
            <Button x:Name="BtnUndoChecked" Content="Deshacer seleccionados" Style="{StaticResource Accent}"/>
            <Button x:Name="BtnUndoAll" Content="Deshacer todo"/>
          </WrapPanel>
          <TextBlock x:Name="UndoNote" Grid.Row="1" Style="{StaticResource Note}"/>
          <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="UndoPanel" Margin="0,0,8,0"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <TabItem Header="No hacemos" x:Name="TabMitos">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="MythsPanel" Margin="14,4,14,10"/>
        </ScrollViewer>
      </TabItem>
    </TabControl>

    <Border Grid.Row="2" Background="#141417" Padding="16,6">
      <DockPanel>
        <ProgressBar x:Name="Busy" Width="140" Height="6" IsIndeterminate="True" Visibility="Collapsed" DockPanel.Dock="Right" Margin="12,0,0,0"/>
        <TextBlock x:Name="RebootNote" Foreground="#F5B400" DockPanel.Dock="Right" Margin="12,0,0,0" TextTrimming="CharacterEllipsis" MaxWidth="520"/>
        <TextBlock x:Name="Status" Foreground="#9A9AA5" TextTrimming="CharacterEllipsis" Text="Listo."/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

function Get-JuicerGuiNames {
    param([string]$Xaml = $script:GuiXaml)
    $doc = [xml]$Xaml
    # Names inside control templates belong to each template, not the window.
    @($doc.SelectNodes("//*[@*[local-name()='Name']][not(ancestor::*[local-name()='ControlTemplate'])]") | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') } | Where-Object { $_ })
}

# --- Small builders ------------------------------------------------------------------

function New-JuicerUi {
    param([string]$Type, [hashtable]$Props = @{})
    $o = New-Object "System.Windows.Controls.$Type"
    foreach ($k in $Props.Keys) { $o.$k = $Props[$k] }
    $o
}

function Set-JuicerGridColumn {
    param($Element, [int]$Column)
    ('System.Windows.Controls.Grid' -as [type])::SetColumn($Element, $Column)
}

function New-JuicerTip {
    param([string[]]$Lines)
    New-JuicerUi TextBlock @{ Text = (@($Lines | Where-Object { $_ }) -join "`n`n"); TextWrapping = 'Wrap'; MaxWidth = 480 }
}

# Silent: the tests drive the window with nobody to click, so messages are
# collected and every question is answered «No».
function Show-JuicerGuiMessage {
    param([string]$Text, [string]$Kind = 'Information', [string]$Buttons = 'OK')
    if ($null -ne $script:Gui.Silent) { [void]$script:Gui.Silent.Add("[$Kind] $Text"); return 'No' }
    $mb = 'System.Windows.MessageBox' -as [type]
    [string]$mb::Show($script:Gui.Window, $Text, 'Win Juicer', $Buttons, $Kind)
}

function Confirm-JuicerGui {
    param([string]$Text, [string]$Kind = 'Question')
    (Show-JuicerGuiMessage $Text $Kind 'YesNo') -eq 'Yes'
}

function Set-JuicerGuiStatus {
    param([string]$Text)
    $script:Gui.C.Status.Text = $Text
}

function Set-JuicerGuiBusy {
    param([bool]$Busy, [string]$Text = '')
    $script:Gui.C.Busy.Visibility = $(if ($Busy) { 'Visible' } else { 'Collapsed' })
    foreach ($name in $script:Gui.C.Keys) {
        if ($name -like 'Btn*') { $script:Gui.C[$name].IsEnabled = -not $Busy }
    }
    foreach ($p in 'PrefPanel', 'CompPanel', 'StartupPanel') { $script:Gui.C[$p].IsEnabled = -not $Busy }
    if ($Text) { Set-JuicerGuiStatus $Text }
}

# --- Background work -----------------------------------------------------------------
#
# Each piece of work runs as a scriptblock inside the module, in a runspace
# of its own. The runner gives it $Sync, whose Status is shown live in the
# status bar, and $A, the arguments. It returns one hashtable.

$script:GuiWork = @{
    Init       = {
        $Sync.Status = 'Leyendo el hardware…'
        $hw = Get-JuicerHardwareProfile
        $Sync.Status = 'Comprobando el estado de cada ajuste…'
        $Sync.Status = 'Buscando versiones nuevas…'
        @{ Hw = $hw; Advice = (Get-JuicerAdvice $hw); Snapshot = (Get-JuicerGuiSnapshot); Update = (Get-JuicerUpdateNotice) }
    }
    Frames     = {
        @{ Findings = @(Invoke-JuicerFrameCapture -Seconds ([int]$A.Seconds) -Delay 10 -OnStatus { param($t) $Sync.Status = $t }) }
    }
    FineTune   = {
        if ($A.Save) {
            $Sync.Status = 'Apuntando tu ajuste…'
            [void](Save-JuicerTuneRecord -Cpu $A.Cpu -Gpu $A.Gpu -GpuTool $A.Tool)
            if ($A.Watch) { Register-JuicerTuneWatch } else { Unregister-JuicerTuneWatch }
        }
        if ($A.Forget) { Remove-JuicerTuneRecord; Unregister-JuicerTuneWatch }
        $Sync.Status = 'Comprobando tu ajuste fino…'
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { Get-JuicerGpuTraits $_.Name })
        @{
            Guide = @(Get-JuicerTuneGuideFindings (Get-JuicerCpuInfo) $gpus (Test-JuicerLaptop) | Where-Object { $_.Title -notlike 'Apunta en Win Juicer*' })
            Check = @(Get-JuicerTuneCheck); Record = (Read-JuicerTuneRecord); Watch = (Test-JuicerTuneWatch)
        }
    }
    Measure    = {
        $Sync.Status = 'Midiendo arranque, procesos y memoria…'
        @{ Findings = @(Invoke-JuicerMeasure -Reset:([bool]$A.Reset)) }
    }
    Audit      = {
        $f = @(Get-JuicerAudit -OnSection { param($n) $Sync.Status = "Revisando: $n…" })
        @{ Findings = $f }
    }
    Run        = {
        $tweaks = @()
        foreach ($id in @($A.Ids)) { $t = Find-JuicerTweak $id; if ($t) { $tweaks += $t } }
        foreach ($n in @($A.Apps)) { $app = Find-JuicerDebloatApp $n; if ($app) { $tweaks += New-JuicerAppxTweak $app } }
        if ($A.Dns) { $tweaks += New-JuicerDnsTweak $A.Dns }
        foreach ($g in @($A.Games)) {
            $tweaks += switch ($g.Kind) {
                'defender' { New-JuicerDefenderTweak $g.Path $g.Launcher }
                'gpu' { New-JuicerGpuTweak $g.Path }
                'prioridad' { New-JuicerPriorityTweak $g.Path }
            }
        }
        $results = @()
        $rp = $null
        if ($A.RestorePoint -and -not $A.Simulate -and $tweaks.Count -gt 0) {
            $Sync.Status = 'Creando punto de restauración…'
            $rp = New-JuicerRestorePoint
        }
        $i = 0
        foreach ($t in $tweaks) {
            $i++
            $Sync.Status = "($i/$($tweaks.Count)) $($t.Title)"
            $results += Invoke-JuicerTweak $t -Simulate:([bool]$A.Simulate)
        }
        foreach ($tg in @($A.Toggles)) {
            $t = Find-JuicerTweak $tg.Id
            if ($t) { $Sync.Status = $t.Title; $results += @(Set-JuicerToggle $t ([bool]$tg.On)) }
        }
        foreach ($id in @($A.Undo)) { $Sync.Status = "Deshaciendo $id"; $results += Undo-JuicerTweak $id }
        $Sync.Status = 'Comprobando el estado…'
        @{
            Results  = @($results | ForEach-Object { @{ Id = $_.Id; Title = $_.Title; Outcome = $_.Outcome; Message = $_.Message; Reboot = $_.Reboot; Changes = @($_.Changes) } })
            Rp       = $rp
            Snapshot = (Get-JuicerGuiSnapshot)
        }
    }
    Debloat    = {
        $Sync.Status = 'Leyendo las apps instaladas…'
        @{ Apps = @(Get-JuicerDebloatState (Get-JuicerHardwareProfile)); Snapshot = (Get-JuicerGuiSnapshot) }
    }
    Startup    = {
        $r = @()
        if ($A.Item) { $r = @(Set-JuicerStartupItem $A.Item ([bool]$A.Enable)) }
        foreach ($i in @($A.Disable)) { $Sync.Status = "Desactivando $($i.Name)…"; $r += Set-JuicerStartupItem $i $false }
        @{ Items = @(Get-JuicerStartupReview); Results = @($r | ForEach-Object { @{ Id = $_.Id; Title = $_.Title; Outcome = $_.Outcome; Message = $_.Message; Reboot = $_.Reboot } }) }
    }
    Games      = {
        $Sync.Status = 'Buscando bibliotecas de juegos…'
        $journal = Read-JuicerJournal
        $libs = @(foreach ($l in @(Get-JuicerGameLibraries)) {
                @{ Path = $l.Path; Launcher = $l.Launcher; State = (Get-JuicerTweakState (New-JuicerDefenderTweak $l.Path $l.Launcher) $journal).State }
            })
        $Sync.Status = 'Leyendo el monitor y los límites de FPS…'
        $lim = Get-JuicerGuiLimiter
        $Sync.Status = 'Buscando tus juegos…'
        @{ Libraries = $libs; Limiter = $lim; Games = @(Get-JuicerGuiGameList) }
    }
    GameSetup  = {
        $r = @()
        switch ($A.What) {
            'SetExe' { Set-JuicerGameExe $A.Id $A.Exe }
            'Add' { [void](Add-JuicerCustomGame $A.Exe) }
            'Refresh' { }
            default {
                $Sync.Status = 'Configurando tus juegos…'
                $r = @(Invoke-JuicerGameSetup @($A.Games) $A.What ([int]$A.Fps))
            }
        }
        $Sync.Status = 'Buscando tus juegos…'
        @{
            Games = @(Get-JuicerGuiGameList); Limiter = (Get-JuicerGuiLimiter)
            Results = @($r | Where-Object { $_ } | ForEach-Object { @{ Id = $_.Id; Title = $_.Title; Outcome = $_.Outcome; Message = $_.Message; Reboot = $_.Reboot } })
        }
    }
    Limiter    = {
        $r = @()
        if ($A.Recalc) { $Sync.Status = 'Recalculando los límites…'; $r += @(Update-JuicerFpsLimits) }
        foreach ($exe in @($A.Add)) { $Sync.Status = "Limitando $exe…"; $r += Add-JuicerFpsLimit $exe ([int]$A.Fps) }
        foreach ($id in @($A.Remove)) { $Sync.Status = "Quitando $id…"; $r += Undo-JuicerTweak $id }
        @{ Limiter = (Get-JuicerGuiLimiter); Results = @($r | ForEach-Object { @{ Id = $_.Id; Title = $_.Title; Outcome = $_.Outcome; Message = $_.Message; Reboot = $_.Reboot } }) }
    }
    MonitorMode = {
        $m = Get-JuicerPrimaryMonitor
        if (-not $m) { throw 'No se pudo leer el monitor.' }
        [void](Set-JuicerMonitorMode $m $A.Mode)
        @{ Limiter = (Get-JuicerGuiLimiter) }
    }
    Installed  = {
        $Sync.Status = 'Preguntando a winget qué está instalado…'
        @{ Installed = (Get-JuicerWingetInstalled); Winget = (Test-JuicerWinget) }
    }
    Restore    = {
        $Sync.Status = 'Creando punto de restauración…'
        @{ Rp = (New-JuicerRestorePoint) }
    }
}

# Everything the window shows about the catalog's state, as plain data.
function Get-JuicerGuiSnapshot {
    $journal = Read-JuicerJournal
    $states = @{}
    foreach ($t in (Get-JuicerCatalog)) {
        $s = Get-JuicerTweakState $t $journal
        $inv = $null
        if ($t.Off) { $inv = (Get-JuicerTweakState (Get-JuicerInverseTweak $t) $journal).State }
        $states[$t.Id] = @{ State = $s.State; Reason = $s.Reason; Undoable = $s.Undoable; Inverse = $inv }
    }
    $dns = @()
    try { $dns = @(Get-JuicerCurrentDns) } catch { Write-JuicerLog "Sin DNS actual: $_" }
    @{ States = $states; Dns = $dns }
}

# One task at a time; what arrives meanwhile (a tab opened during the
# diagnosis) waits its turn instead of being dropped.
# First: ahead of what is queued, for the tab the user is looking at.
function Start-JuicerGuiTask {
    param([string]$Status, [string]$Work, [hashtable]$Arguments = @{}, [scriptblock]$Done, [switch]$First)
    if ($script:Gui.Task) {
        $dup = $Arguments.Count -eq 0 -and @($script:Gui.Queue | Where-Object { $_.Work -eq $Work -and $_.Arguments.Count -eq 0 }).Count -gt 0
        if (-not $dup) {
            $item = @{ Status = $Status; Work = $Work; Arguments = $Arguments; Done = $Done }
            if ($First) { $script:Gui.Queue.Insert(0, $item) } else { [void]$script:Gui.Queue.Add($item) }
        }
        return
    }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('JuicerSync', $script:Gui.Sync)
    $rs.SessionStateProxy.SetVariable('JuicerArgs', $Arguments)
    $psm = Join-Path (Split-Path -Parent $PSScriptRoot) 'WinJuicer.psm1'
    $body = $script:GuiWork[$Work].ToString()
    $code = "Import-Module '$($psm -replace "'", "''")' -Force`n& (Get-Module WinJuicer) {`nparam(`$Sync, `$A)`n$body`n} `$JuicerSync `$JuicerArgs"
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($code)
    $script:Gui.Sync.Status = ''
    $script:Gui.Task = @{ PS = $ps; Runspace = $rs; Handle = $ps.BeginInvoke(); Done = $Done; Work = $Work }
    Set-JuicerGuiBusy $true $Status
    $script:Gui.Timer.Start()
}

function Complete-JuicerGuiTask {
    $t = $script:Gui.Task
    if ($script:Gui.Sync.Status) { Set-JuicerGuiStatus $script:Gui.Sync.Status }
    if (-not $t -or -not $t.Handle.IsCompleted) { return }
    $script:Gui.Timer.Stop()
    $script:Gui.Task = $null
    $out = $null
    $err = $null
    try {
        $out = @($t.PS.EndInvoke($t.Handle))
        if ($t.PS.Streams.Error.Count -gt 0) { $err = $t.PS.Streams.Error[0] }
    } catch {
        $err = $_
    }
    $t.PS.Dispose()
    $t.Runspace.Dispose()
    Set-JuicerGuiBusy $false 'Listo.'
    $result = $null
    if ($out.Count -gt 0 -and $null -ne $out[-1]) { $result = $out[-1].psobject.BaseObject }
    if ($result -isnot [hashtable]) {
        Write-JuicerLog "La tarea $($t.Work) falló: $err"
        Show-JuicerGuiMessage "Algo falló ($($t.Work)): $err" 'Error' | Out-Null
    } else {
        if ($err) { Write-JuicerLog "Aviso en $($t.Work): $err" }
        try {
            & $t.Done $result
        } catch {
            Write-JuicerLog "Error al mostrar $($t.Work): $_"
            Show-JuicerGuiMessage "Error al mostrar el resultado: $_" 'Error' | Out-Null
        }
    }
    if (-not $script:Gui.Task -and $script:Gui.Queue.Count -gt 0) {
        $next = $script:Gui.Queue[0]
        $script:Gui.Queue.RemoveAt(0)
        Start-JuicerGuiTask $next.Status $next.Work $next.Arguments $next.Done
    }
}

# --- Drawing ---------------------------------------------------------------------------

function Get-JuicerGuiTweakTip {
    param([hashtable]$Tweak)
    $s = $script:Gui.Snapshot.States[$Tweak.Id]
    $a = $script:Gui.Advice[$Tweak.Id]
    $rb = @{ No = 'efecto inmediato'; Explorador = 'reinicia el Explorador'; Sesion = 'al volver a iniciar sesión'; Reinicio = 'tras reiniciar' }[$Tweak.Reboot]
    $verdict = @{ Recomendado = 'Recomendado'; Opcional = 'Opcional'; NoRecomendado = 'No recomendado' }
    New-JuicerTip @(
        ('{0} · impacto {1} · {2}' -f $script:LevelNames[[int]$Tweak.Level], $Tweak.Impact.ToLowerInvariant(), $rb)
        "Qué hace: $($Tweak.What)"
        "Qué ganas: $($Tweak.Gain)"
        "Qué cuesta: $($Tweak.Cost)"
        $(if ($a) { "Para este equipo: $($verdict[$a.Verdict]). $($a.Reason)" })
        $(if ($s -and $s.Reason) { $s.Reason })
    )
}

function Get-JuicerStateSuffix {
    param([string]$State)
    switch ($State) {
        'Aplicado' { return @('  ✓', '#4CC38A') }
        'Parcial' { return @('  ~ a medias', '#F5B400') }
        'NoAplica' { return @('  – no aplica', '#6E6E78') }
        'Error' { return @('  ! sin leer', '#E5484D') }
    }
    @('', '#9A9AA5')
}

function New-JuicerTweakCheck {
    param([hashtable]$Tweak)
    $s = $script:Gui.Snapshot.States[$Tweak.Id]
    $a = $script:Gui.Advice[$Tweak.Id]
    $state = if ($s) { $s.State } else { 'Pendiente' }
    $row = New-JuicerUi StackPanel @{ Orientation = 'Horizontal' }
    $star = if ($a -and $a.Verdict -eq 'Recomendado') { '★ ' } else { '' }
    [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = $star; Foreground = '#F5B400' }))
    $titleColor = if ($Tweak.Level -eq 3) { '#FF8A80' } else { '#E8E8E8' }
    [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = $Tweak.Title; Foreground = $titleColor }))
    $suffix = Get-JuicerStateSuffix $state
    [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = $suffix[0]; Foreground = $suffix[1] }))
    $cb = New-JuicerUi CheckBox @{ Content = $row; Tag = $Tweak.Id; ToolTip = (Get-JuicerGuiTweakTip $Tweak) }
    if ($state -eq 'NoAplica' -or ($state -eq 'Aplicado' -and -not $s.Undoable)) { $cb.Opacity = 0.6 }
    if ($state -eq 'NoAplica') { $cb.IsEnabled = $false }
    $script:Gui.Checks[$Tweak.Id] = $cb
    $cb
}

function Show-JuicerGuiTweaks {
    $c = $script:Gui.C
    $checked = @($script:Gui.Checks.Keys | Where-Object { $script:Gui.Checks[$_].IsChecked })
    $script:Gui.Checks = @{}
    $c.TweaksLeft.Children.Clear()
    $c.TweaksRight.Children.Clear()
    $catalog = @(Get-JuicerCatalog)
    $groups = @(foreach ($cat in $script:CategoryOrder) {
            if ($cat -in 'Preferencias', 'Componentes', 'Apps') { continue }
            $items = @($catalog | Where-Object { $_.Category -eq $cat })
            if ($items.Count -gt 0) { @{ Name = $cat; Items = $items } }
        })
    $cols = Split-JuicerColumns $groups
    $panels = @($c.TweaksLeft, $c.TweaksRight)
    for ($i = 0; $i -lt 2; $i++) {
        foreach ($g in $cols[$i]) {
            [void]$panels[$i].Children.Add((New-JuicerUi TextBlock @{ Text = $g.Name; Foreground = '#F5B400'; FontWeight = 'SemiBold'; FontSize = 14; Margin = '2,12,2,4' }))
            foreach ($t in $g.Items) {
                $cb = New-JuicerTweakCheck $t
                $s = $script:Gui.Snapshot.States[$t.Id]
                if ($checked -contains $t.Id -and $cb.IsEnabled -and $s -and $s.State -in 'Pendiente', 'Parcial') { $cb.IsChecked = $true }
                [void]$panels[$i].Children.Add($cb)
            }
        }
    }
    Show-JuicerGuiToggles 'Preferencias' $c.PrefPanel
    Show-JuicerGuiToggles 'Componentes' $c.CompPanel
    Show-JuicerGuiPowerAndDns
}

# Preferences and components: checked means on, and a click applies.
function Show-JuicerGuiToggles {
    param([string]$Category, $Panel)
    $Panel.Children.Clear()
    foreach ($t in @(Get-JuicerCatalog | Where-Object { $_.Category -eq $Category })) {
        $s = $script:Gui.Snapshot.States[$t.Id]
        $cb = New-JuicerUi CheckBox @{ Content = $t.Title; Tag = $t.Id; ToolTip = (Get-JuicerGuiTweakTip $t) }
        $cb.IsChecked = ($s -and $s.State -eq 'Aplicado')
        if (-not $s -or $s.State -in 'NoAplica', 'Error') { $cb.IsEnabled = $false; $cb.Opacity = 0.6 }
        $cb.Add_Click({
                $id = [string]$this.Tag
                $on = [bool]$this.IsChecked
                Start-JuicerGuiTask 'Aplicando…' 'Run' @{ Toggles = @(@{ Id = $id; On = $on }) } { param($r) Complete-JuicerGuiRun $r }
            })
        [void]$Panel.Children.Add($cb)
    }
}

function Show-JuicerGuiPowerAndDns {
    $c = $script:Gui.C
    $plan = $script:Gui.Snapshot.States['energia.plan']
    $mode = $script:Gui.Snapshot.States['energia.modo']
    $script:Gui.PlanId = if ($plan -and $plan.State -ne 'NoAplica') { 'energia.plan' } elseif ($mode -and $mode.State -ne 'NoAplica') { 'energia.modo' } else { $null }
    $note = switch ($script:Gui.PlanId) {
        'energia.plan' { 'Plan «Win Juicer»: Máximo rendimiento, sin aparcar núcleos ni ahorro en PCIe, USB ni disco. ' + $(if ($plan.State -eq 'Aplicado') { 'Activo.' } else { 'No activo.' }) }
        'energia.modo' { 'Este equipo usa Modern Standby: lo que vale aquí es «Modo de energía: mejor rendimiento». ' + $(if ($mode.State -eq 'Aplicado') { 'Activo.' } else { 'No activo.' }) }
        default { if ($plan -and $plan.Reason) { $plan.Reason } else { 'No disponible en este equipo.' } }
    }
    $a = $script:Gui.Advice['energia.plan']
    if ($script:Gui.PlanId -eq 'energia.plan' -and $a -and $a.Verdict -eq 'NoRecomendado') { $note += " $($a.Reason)" }
    $c.PlanNote.Text = $note
    $c.BtnPlanAdd.Visibility = $(if ($script:Gui.PlanId) { 'Visible' } else { 'Collapsed' })
    $c.BtnPlanRemove.Visibility = $c.BtnPlanAdd.Visibility

    $c.DnsCombo.Items.Clear()
    $providers = Get-JuicerDnsProviders
    foreach ($k in $providers.Keys) { [void]$c.DnsCombo.Items.Add((New-JuicerUi ComboBoxItem @{ Content = $providers[$k].Title; Tag = $k; ToolTip = $providers[$k].What })) }
    $dns = @($script:Gui.Snapshot.Dns)
    if ($dns.Count -eq 0) {
        $c.DnsNote.Text = 'No hay ningún adaptador de red físico conectado.'
    } else {
        $c.DnsNote.Text = (@($dns | ForEach-Object {
                    $what = if ($_.Provider -ne 'Otro') { $providers[$_.Provider].Title } else { (@($_.V4) + @($_.V6)) -join ', ' }
                    "$($_.Adapter): $what"
                }) -join "`n") + "`nNo baja el ping: sirve para privacidad o para filtrar malware o anuncios."
        $first = $dns[0].Provider
        for ($i = 0; $i -lt $c.DnsCombo.Items.Count; $i++) { if ($c.DnsCombo.Items[$i].Tag -eq $first) { $c.DnsCombo.SelectedIndex = $i } }
    }
    $c.BtnDnsUndo.Visibility = $(if (Get-JuicerJournalEntry (Read-JuicerJournal) 'red.dns') { 'Visible' } else { 'Collapsed' })
}

function New-JuicerFindingCard {
    param([hashtable]$Finding)
    $colors = @{ Alto = '#E5484D'; Medio = '#F5B400'; Bajo = '#4EA1FF'; Info = '#6E6E78'; Ok = '#4CC38A' }
    $labels = @{ Alto = 'ALTO'; Medio = 'MEDIO'; Bajo = 'BAJO'; Info = 'INFO'; Ok = 'OK' }
    $border = New-JuicerUi Border @{ Background = '#1F1F25'; CornerRadius = '5'; Padding = '10,7'; Margin = '0,3' }
    $grid = New-JuicerUi Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition
    $c0.Width = '64'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = 'Auto'
    [void]$grid.ColumnDefinitions.Add($c0); [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)
    $tag = New-JuicerUi TextBlock @{ Text = $labels[$Finding.Severity]; Foreground = $colors[$Finding.Severity]; FontWeight = 'Bold'; FontSize = 11; Margin = '0,2,0,0' }
    [void]$grid.Children.Add($tag)
    $text = New-JuicerUi StackPanel
    Set-JuicerGridColumn $text 1
    [void]$text.Children.Add((New-JuicerUi TextBlock @{ Text = $Finding.Title; TextWrapping = 'Wrap'; FontWeight = $(if ($Finding.Severity -in 'Alto', 'Medio') { 'SemiBold' } else { 'Normal' }) }))
    if ($Finding.Detail) { [void]$text.Children.Add((New-JuicerUi TextBlock @{ Text = $Finding.Detail; TextWrapping = 'Wrap'; Foreground = '#9A9AA5'; Margin = '0,2,0,0' })) }
    [void]$grid.Children.Add($text)
    $fix = $Finding.Fix
    $s = if ($fix -and $script:Gui.Snapshot) { $script:Gui.Snapshot.States[$fix] } else { $null }
    if ($s -and $s.State -in 'Pendiente', 'Parcial') {
        $btn = New-JuicerUi Button @{ Content = 'Aplicar'; Tag = $fix; Margin = '8,0,0,0'; VerticalAlignment = 'Top' }
        Set-JuicerGridColumn $btn 2
        $btn.Add_Click({ Invoke-JuicerGuiApply @([string]$this.Tag) })
        [void]$grid.Children.Add($btn)
    }
    $border.Child = $grid
    $border
}

function Show-JuicerGuiAudit {
    param([object[]]$Findings)
    $p = $script:Gui.C.AuditPanel
    $p.Children.Clear()
    [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = 'Este equipo'; Foreground = '#F5B400'; FontWeight = 'SemiBold'; FontSize = 14; Margin = '2,4,2,4' }))
    foreach ($l in (Format-JuicerHardwareSummary $script:Gui.Hw)) { [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = $l; TextWrapping = 'Wrap'; Margin = '2,1' })) }
    if (@($script:Gui.Measure).Count -gt 0) {
        [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = 'Antes y después'; Foreground = '#F5B400'; FontWeight = 'SemiBold'; FontSize = 14; Margin = '2,14,2,4' }))
        foreach ($f in $script:Gui.Measure) { [void]$p.Children.Add((New-JuicerFindingCard $f)) }
    }
    $top = @($Findings | Where-Object { $_.Severity -in 'Alto', 'Medio' } | Sort-Object { $script:SeverityOrder[$_.Severity] })
    if ($top.Count -gt 0) {
        [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = 'Lo que más rinde arreglar'; Foreground = '#F5B400'; FontWeight = 'SemiBold'; FontSize = 14; Margin = '2,14,2,4' }))
        foreach ($f in $top) { [void]$p.Children.Add((New-JuicerFindingCard $f)) }
    } elseif (@($Findings).Count -gt 0) {
        [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = 'No hay nada grave. «Aplicar lo recomendado» exprime lo que queda.'; Foreground = '#4CC38A'; Margin = '2,14,2,4' }))
    }
    $area = ''
    foreach ($f in @($Findings | Where-Object { $_.Severity -notin 'Alto', 'Medio' })) {
        if ($f.Area -ne $area) {
            $area = $f.Area
            [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = $area; Foreground = '#F5B400'; FontWeight = 'SemiBold'; FontSize = 14; Margin = '2,14,2,4' }))
        }
        [void]$p.Children.Add((New-JuicerFindingCard $f))
    }
}

function Show-JuicerGuiDebloat {
    param([object[]]$Apps)
    $p = $script:Gui.C.DebloatPanel
    $p.Children.Clear()
    $script:Gui.AppChecks = @{}
    $headers = @{ Seguro = 'Seguras de quitar'; Opcional = 'Opcionales: léelas antes'; Cuidado = 'Con cuidado: algo depende de ellas' }
    foreach ($class in 'Seguro', 'Opcional', 'Cuidado') {
        $in = @($Apps | Where-Object { $_.Class -eq $class })
        if ($in.Count -eq 0) { continue }
        [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = $headers[$class]; Foreground = '#F5B400'; FontWeight = 'SemiBold'; FontSize = 14; Margin = '2,12,2,4' }))
        $wrap = New-JuicerUi WrapPanel
        foreach ($a in $in) {
            $row = New-JuicerUi StackPanel @{ Orientation = 'Horizontal' }
            [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = $a.Title }))
            if ($a.Need) { [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = '  necesaria aquí'; Foreground = '#F5B400' })) }
            $cb = New-JuicerUi CheckBox @{ Content = $row; Tag = $a.Name; Width = 330; ToolTip = (New-JuicerTip @($a.What, $(if ($a.Need) { "Necesaria aquí: $($a.Need)" }))) }
            $script:Gui.AppChecks[$a.Name] = @{ Check = $cb; App = $a }
            [void]$wrap.Children.Add($cb)
        }
        [void]$p.Children.Add($wrap)
    }
    foreach ($t in @(Get-JuicerCatalog | Where-Object { $_.Category -eq 'Apps' })) {
        $s = $script:Gui.Snapshot.States[$t.Id]
        if (-not $s -or $s.State -notin 'Pendiente', 'Parcial') { continue }
        [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = 'Otros'; Foreground = '#F5B400'; FontWeight = 'SemiBold'; FontSize = 14; Margin = '2,12,2,4' }))
        $cb = New-JuicerUi CheckBox @{ Content = $t.Title; Tag = $t.Id; ToolTip = (Get-JuicerGuiTweakTip $t) }
        $script:Gui.AppChecks[$t.Id] = @{ Check = $cb; Tweak = $t }
        [void]$p.Children.Add($cb)
    }
    if ($script:Gui.AppChecks.Count -eq 0) {
        [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = 'No queda instalada ninguna de las apps que Win Juicer sabe quitar.'; Foreground = '#4CC38A'; Margin = '2,12' }))
    }
}

function Show-JuicerGuiApps {
    $p = $script:Gui.C.AppsPanel
    $p.Children.Clear()
    $script:Gui.InstallChecks = @{}
    $suggest = Get-JuicerAppSuggestions $script:Gui.Hw
    $installed = $script:Gui.Installed
    foreach ($cat in $script:WingetCategories) {
        $col = New-JuicerUi StackPanel @{ Width = 290; Margin = '0,0,14,6' }
        [void]$col.Children.Add((New-JuicerUi TextBlock @{ Text = $cat; Foreground = '#F5B400'; FontWeight = 'SemiBold'; FontSize = 14; Margin = '2,10,2,4' }))
        foreach ($a in @(Get-JuicerWingetApps | Where-Object { $_.Category -eq $cat })) {
            $has = $installed -and $installed.ContainsKey($a.Id.ToLowerInvariant())
            $sug = $suggest.Contains($a.Id)
            $label = $(if ($sug -and -not $has) { '★ ' } else { '' }) + $a.Name + $(if ($has) { '  ✓' } else { '' })
            $cb = New-JuicerUi CheckBox @{ Content = $label; Tag = $a.Id; ToolTip = (New-JuicerTip @($a.What, $(if ($sug) { "Para este equipo: $($suggest[$a.Id])" }), "winget: $($a.Id)")) }
            if ($has) { $cb.Foreground = '#4CC38A' }
            $script:Gui.InstallChecks[$a.Id] = @{ Check = $cb; App = $a; Suggested = $sug; Installed = $has }
            [void]$col.Children.Add($cb)
        }
        [void]$p.Children.Add($col)
    }
    Set-JuicerGuiSearch
}

function Set-JuicerGuiSearch {
    $q = ([string]$script:Gui.C.SearchBox.Text).Trim()
    foreach ($e in $script:Gui.InstallChecks.Values) {
        $match = -not $q -or $e.App.Name -like "*$q*" -or $e.App.What -like "*$q*" -or $e.App.Id -like "*$q*"
        $e.Check.Visibility = $(if ($match) { 'Visible' } else { 'Collapsed' })
    }
}

function Show-JuicerGuiStartup {
    param([object[]]$Items)
    $script:Gui.Startup = @($Items)
    $p = $script:Gui.C.StartupPanel
    $p.Children.Clear()
    if (@($Items).Count -eq 0) { [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = 'No hay nada configurado para arrancar al iniciar sesión.'; Foreground = '#4CC38A' })); return }
    foreach ($i in @($Items | Sort-Object { -not $_.Enabled }, { $_.Name })) {
        $row = New-JuicerUi StackPanel @{ Orientation = 'Horizontal' }
        [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = $i.Name; Width = 280; TextTrimming = 'CharacterEllipsis' }))
        [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = $i.Source; Foreground = '#9A9AA5'; Width = 190 }))
        $vc = @{ Prescindible = '#4CC38A'; Opcional = '#F5B400'; Necesario = '#4EA1FF' }
        [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = $(if ($i.Verdict) { $i.Verdict.ToLowerInvariant() } else { '' }); Foreground = $(if ($i.Verdict) { $vc[$i.Verdict] } else { '#9A9AA5' }); Width = 100 }))
        [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = $i.Command; Foreground = '#6E6E78'; TextTrimming = 'CharacterEllipsis'; MaxWidth = 480 }))
        $cb = New-JuicerUi CheckBox @{ Content = $row; Tag = $i; IsChecked = [bool]$i.Enabled; ToolTip = (New-JuicerTip @($i.Why, $i.Command)) }
        $cb.Add_Click({
                $item = $this.Tag
                Start-JuicerGuiTask "Cambiando $($item.Name)…" 'Startup' @{ Item = $item; Enable = [bool]$this.IsChecked } {
                    param($r)
                    Show-JuicerGuiStartup $r.Items
                    $bad = @($r.Results | Where-Object { $_.Outcome -eq 'Error' })
                    if ($bad.Count -gt 0) { Show-JuicerGuiMessage (Format-JuicerResultsText $r.Results) 'Warning' | Out-Null }
                    Show-JuicerGuiUndo
                }
            })
        [void]$p.Children.Add($cb)
    }
}

function Show-JuicerGuiUndo {
    $c = $script:Gui.C
    $c.UndoPanel.Children.Clear()
    $script:Gui.UndoChecks = @{}
    $journal = Read-JuicerJournal
    $c.UndoNote.Text = "Deshacer devuelve cada cambio a como estaba antes de que Win Juicer lo tocara por primera vez. Las apps quitadas se reinstalan desde Microsoft Store. Diario: $(Get-JuicerJournalPath)"
    if ($journal.Count -eq 0) {
        [void]$c.UndoPanel.Children.Add((New-JuicerUi TextBlock @{ Text = 'No hay cambios de Win Juicer que deshacer.'; Foreground = '#4CC38A' }))
        return
    }
    foreach ($e in $journal) {
        $when = ''
        try { $when = ([datetime]$e.AppliedAt).ToString('g') } catch { $when = [string]$e.AppliedAt }
        $row = New-JuicerUi StackPanel @{ Orientation = 'Horizontal' }
        [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = $e.Title; Width = 520; TextTrimming = 'CharacterEllipsis' }))
        [void]$row.Children.Add((New-JuicerUi TextBlock @{ Text = $when; Foreground = '#9A9AA5' }))
        $cb = New-JuicerUi CheckBox @{ Content = $row; Tag = $e.Id }
        $script:Gui.UndoChecks[$e.Id] = $cb
        [void]$c.UndoPanel.Children.Add($cb)
    }
}

function Show-JuicerGuiMyths {
    $p = $script:Gui.C.MythsPanel
    $p.Children.Clear()
    [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = 'Los «trucos» que circulan y Win Juicer no hace, o hace de otra forma. O no hacen nada medible, o rompen algo, o las dos cosas.'; Foreground = '#9A9AA5'; TextWrapping = 'Wrap'; Margin = '2,8,2,4' }))
    foreach ($m in (Get-JuicerMyths)) {
        [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = "× $($m.Title)"; Foreground = '#F5B400'; FontWeight = 'SemiBold'; TextWrapping = 'Wrap'; Margin = '2,12,2,2' }))
        [void]$p.Children.Add((New-JuicerUi TextBlock @{ Text = $m.Why; TextWrapping = 'Wrap'; Foreground = '#C8C8D0'; Margin = '14,0,2,0' }))
    }
}

function Show-JuicerGuiResults {
    param([object[]]$Results, $RestorePoint)
    $text = Format-JuicerResultsText $Results
    if ($RestorePoint) { $text = $RestorePoint.Message + "`n`n" + $text }
    $kind = if (@($Results | Where-Object { $_.Outcome -eq 'Error' }).Count -gt 0) { 'Warning' } else { 'Information' }
    if ($text.Trim()) { Show-JuicerGuiMessage $text $kind | Out-Null }
    $done = @($Results | Where-Object { $_.Outcome -in 'Aplicado', 'Deshecho', 'NoSeMantuvo' })
    $reboot = @($done | Where-Object { $_.Reboot -eq 'Reinicio' })
    if ($reboot.Count -gt 0) { $script:Gui.C.RebootNote.Text = 'Reinicia el equipo para completar algunos cambios.' }
    if (@($done | Where-Object { $_.Reboot -eq 'Explorador' }).Count -gt 0) {
        if (Confirm-JuicerGui '¿Reinicio el Explorador ahora para ver los cambios? Se cerrarán las ventanas de carpetas.') { Restart-JuicerExplorer }
    }
}

# --- Actions -----------------------------------------------------------------------------

function Complete-JuicerGuiRun {
    param([hashtable]$R)
    $script:Gui.Snapshot = $R.Snapshot
    Show-JuicerGuiTweaks
    Show-JuicerGuiUndo
    Show-JuicerGuiResults $R.Results $R.Rp
    if ($script:Gui.DebloatLoaded -and @($R.Results | Where-Object { $_.Id -like 'app*' }).Count -gt 0) { Start-JuicerGuiDebloat }
}

function Invoke-JuicerGuiApply {
    param([string[]]$Ids, [switch]$Simulate)
    $catalog = @(Get-JuicerCatalog)
    $tweaks = @($catalog | Where-Object { $Ids -contains $_.Id })
    if ($tweaks.Count -eq 0) { Show-JuicerGuiMessage 'No hay nada seleccionado que aplicar.' | Out-Null; return }
    if (-not $Simulate) {
        foreach ($t in @($tweaks | Where-Object { $_.Level -ge 3 })) {
            if (-not (Confirm-JuicerGui "EXTREMO: $($t.Title)`n`nGanas: $($t.Gain)`n`nPierdes: $($t.Cost)`n`n¿Aplicarlo?" 'Warning')) {
                $tweaks = @($tweaks | Where-Object { $_.Id -ne $t.Id })
            }
        }
        if ($tweaks.Count -eq 0) { return }
        $list = ($tweaks | ForEach-Object { '· ' + $_.Title }) -join "`n"
        if (-not (Confirm-JuicerGui "Se aplicará:`n`n$list`n`n¿Seguir?")) { return }
    }
    $verb = if ($Simulate) { 'Simulando…' } else { 'Aplicando…' }
    Start-JuicerGuiTask $verb 'Run' @{ Ids = @($tweaks | ForEach-Object { $_.Id }); Simulate = [bool]$Simulate; RestorePoint = [bool]$script:Gui.C.ChkRestorePoint.IsChecked } { param($r) Complete-JuicerGuiRun $r }
}

function Start-JuicerGuiAudit {
    Start-JuicerGuiTask 'Revisando el equipo…' 'Audit' @{} {
        param($r)
        $script:Gui.Findings = @($r.Findings)
        Show-JuicerGuiAudit $script:Gui.Findings
        Set-JuicerGuiStatus 'Diagnóstico terminado.'
    }
}

function Start-JuicerGuiMeasure {
    param([bool]$Reset)
    Start-JuicerGuiTask 'Midiendo…' 'Measure' @{ Reset = $Reset } {
        param($r)
        $script:Gui.Measure = @($r.Findings)
        Show-JuicerGuiAudit $script:Gui.Findings
        Set-JuicerGuiStatus 'Medida hecha: está arriba del todo en Equipo.'
    }
}

function Start-JuicerGuiDebloat {
    $script:Gui.DebloatLoaded = $true
    Start-JuicerGuiTask 'Leyendo las apps instaladas…' 'Debloat' @{} {
        param($r)
        $script:Gui.Snapshot = $r.Snapshot
        Show-JuicerGuiDebloat $r.Apps
    }
}

function Start-JuicerGuiInstalled {
    Start-JuicerGuiTask 'Preguntando a winget qué está instalado…' 'Installed' @{} {
        param($r)
        $script:Gui.Installed = $r.Installed
        $script:Gui.Winget = [bool]$r.Winget
        if (-not $r.Winget) { $script:Gui.C.InstallNote.Text = 'winget no está disponible: instala o actualiza «Instalador de aplicación» desde Microsoft Store.' }
        Show-JuicerGuiApps
    }
}

function Start-JuicerGuiFineTune {
    param([hashtable]$Arguments = @{})
    Start-JuicerGuiTask 'Leyendo tu ajuste fino…' 'FineTune' $Arguments {
        param($r)
        $c = $script:Gui.C
        $c.FineGuidePanel.Children.Clear()
        foreach ($f in @($r.Guide)) { [void]$c.FineGuidePanel.Children.Add((New-JuicerFindingCard $f)) }
        if (@($r.Guide).Count -eq 0) { [void]$c.FineGuidePanel.Children.Add((New-JuicerUi TextBlock @{ Text = 'Para tus componentes no hay una receta que merezca la pena (portátil, o procesador sin margen).'; Foreground = '#9A9AA5'; TextWrapping = 'Wrap' })) }
        $c.FineCheckPanel.Children.Clear()
        foreach ($f in @($r.Check)) { [void]$c.FineCheckPanel.Children.Add((New-JuicerFindingCard $f)) }
        if ($r.Record) {
            $c.FineCpu.Text = [string]$r.Record.Cpu
            $c.FineGpu.Text = [string]$r.Record.Gpu
            foreach ($i in $c.FineGpuTool.Items) { if ([string]$i.Tag -eq [string]$r.Record.GpuTool) { $c.FineGpuTool.SelectedItem = $i } }
            $c.FineWatch.IsChecked = [bool]$r.Watch
        }
        Set-JuicerGuiStatus 'Ajuste fino al día.'
    }
}

function Start-JuicerGuiGames {
    Start-JuicerGuiTask 'Buscando tus juegos…' 'Games' @{} { param($r) Show-JuicerGuiGames $r.Libraries; Show-JuicerGuiLimiter $r.Limiter; Show-JuicerGuiGameList $r.Games } -First
}

# The detected games with what each has, plus measured games that are in no
# launcher (only their .exe name is known).
function Get-JuicerGuiGameList {
    $games = @(Get-JuicerGames)
    $names = @($games | ForEach-Object { $_.ExeName })
    foreach ($exe in @(Get-JuicerUnlimitedGames) + @(Get-JuicerFpsLimits | ForEach-Object { $_.Exe })) {
        if (-not $exe -or $names -contains $exe) { continue }
        $names += $exe
        $games += @{ Id = "medido:$exe"; Name = [IO.Path]::GetFileNameWithoutExtension($exe); Launcher = 'Medido o limitado'; Dir = ''; Exe = $exe; ExeName = $exe; New = $false }
    }
    @(Get-JuicerGameStatus $games)
}

function Show-JuicerGuiGameList {
    param([object[]]$Games)
    $c = $script:Gui.C
    $c.GamesPanel.Children.Clear()
    $new = @($Games | Where-Object { $_.New })
    $two = @($script:Gui.Hw.Gpus).Count -ge 2
    $c.BtnGamesGpu.IsEnabled = $two
    $c.BtnGamesGpu.ToolTip = if ($two) { 'Que estos juegos usen siempre la gráfica dedicada' } else { 'Sólo hay una gráfica: elegir GPU no cambia nada aquí' }
    $c.GamesNote.Text = if (@($Games).Count -eq 0) { 'No he encontrado juegos. Añade uno con su .exe.' } else {
        '{0} juegos encontrados{1}. Márcalos y pulsa «Optimizar los marcados»: el límite de FPS para tu monitor (sin inyectar nada) y, con dos gráficas, la dedicada. Se aplica solo cada vez que abras el juego y se deshace aquí o en Deshacer. Si el .exe no es el bueno, cámbialo.' -f @($Games).Count, $(if ($new.Count -gt 0) { " ($($new.Count) nuevos, ya marcados)" } else { '' })
    }
    foreach ($g in @($Games)) {
        $row = New-JuicerUi Grid @{ Margin = '0,1' }
        foreach ($w in 360, 150, 230, '*', 120) {
            $col = New-Object System.Windows.Controls.ColumnDefinition
            $col.Width = if ($w -eq '*') { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) } else { New-Object System.Windows.GridLength $w }
            $row.ColumnDefinitions.Add($col)
        }
        $title = New-JuicerUi StackPanel @{ Orientation = 'Horizontal' }
        [void]$title.Children.Add((New-JuicerUi TextBlock @{ Text = $g.Name; FontWeight = 'SemiBold'; TextTrimming = 'CharacterEllipsis' }))
        if ($g.New) { [void]$title.Children.Add((New-JuicerUi TextBlock @{ Text = '  nuevo'; Foreground = '#F5B400' })) }
        $cb = New-JuicerUi CheckBox @{ Content = $title; Tag = $g; IsChecked = [bool]$g.New; VerticalAlignment = 'Center' }
        $launcher = New-JuicerUi TextBlock @{ Text = $g.Launcher; Foreground = '#9A9AA5'; VerticalAlignment = 'Center' }
        $exe = New-JuicerUi TextBlock @{ Text = $g.ExeName; Foreground = '#6E6E78'; ToolTip = $g.Exe; TextTrimming = 'CharacterEllipsis'; VerticalAlignment = 'Center' }
        $configured = [bool]($g.Fps -or $g.Gpu -or $g.Priority)
        $status = New-JuicerUi TextBlock @{ Text = (Format-JuicerGameStatus $g); Foreground = $(if ($configured) { '#4CC38A' } else { '#9A9AA5' }); VerticalAlignment = 'Center'; TextTrimming = 'CharacterEllipsis' }
        $btn = New-JuicerUi Button @{ Content = 'Cambiar .exe…'; Tag = $g.Id; IsEnabled = [bool]$g.Dir; Margin = '2,1' }
        $btn.Add_Click({ Select-JuicerGuiGameExe ([string]$this.Tag) })
        $i = 0
        foreach ($e in $cb, $launcher, $exe, $status, $btn) { [System.Windows.Controls.Grid]::SetColumn($e, $i); [void]$row.Children.Add($e); $i++ }
        [void]$c.GamesPanel.Children.Add($row)
    }
}

function Get-JuicerGuiCheckedGames {
    @($script:Gui.C.GamesPanel.Children | ForEach-Object { $_.Children[0] } | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
}

function Set-JuicerGuiGameChecks {
    param([bool]$On)
    foreach ($row in $script:Gui.C.GamesPanel.Children) { $row.Children[0].IsChecked = $On }
}

function Start-JuicerGuiGameSetup {
    param([string]$What, [hashtable]$Extra = @{})
    $args2 = @{ What = $What }
    foreach ($k in $Extra.Keys) { $args2[$k] = $Extra[$k] }
    if ($What -notin 'SetExe', 'Add', 'Refresh') {
        $games = @(Get-JuicerGuiCheckedGames)
        if ($games.Count -eq 0) { Show-JuicerGuiMessage 'Marca primero los juegos.' | Out-Null; return }
        $args2.Games = $games
        if ($What -in 'Recomendado', 'Fps') {
            $t = ([string]$script:Gui.C.LimitFps.Text).Trim()
            if ($t -and ($t -notmatch '^\d+$' -or [int]$t -lt 20 -or [int]$t -gt 1000)) { Show-JuicerGuiMessage 'El límite tiene que ser un número de 20 a 1000, o vacío para el recomendado.' | Out-Null; return }
            $args2.Fps = $(if ($t) { [int]$t } else { 0 })
        }
        if ($What -eq 'Quitar' -and -not (Confirm-JuicerGui "¿Quitar a $($games.Count) juegos todo lo que les puso Win Juicer (límite, GPU, prioridad)?")) { return }
    }
    Start-JuicerGuiTask 'Configurando tus juegos…' 'GameSetup' $args2 {
        param($r)
        Show-JuicerGuiGameList $r.Games
        Show-JuicerGuiLimiter $r.Limiter
        $bad = @($r.Results | Where-Object { $_.Outcome -in 'Error', 'NoAplica' })
        if ($bad.Count -gt 0) { Show-JuicerGuiMessage (($bad | ForEach-Object { '{0}: {1}' -f $_.Title, $_.Message }) -join "`n") 'Warning' | Out-Null }
        Show-JuicerGuiUndo
        Set-JuicerGuiStatus $(if (@($r.Results).Count -gt 0) { 'Juegos configurados: se aplica solo cada vez que los abras.' } else { 'Lista de juegos al día.' })
    }
}

function Select-JuicerGuiGameExe {
    param([string]$Id)
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Filter = 'Juegos (*.exe)|*.exe'
    $d.Title = 'El .exe que se ejecuta de verdad (no el lanzador)'
    if ($d.ShowDialog()) { Start-JuicerGuiGameSetup 'SetExe' @{ Id = $Id; Exe = $d.FileName } }
}

# What the limiter section shows, read in the background.
function Get-JuicerGuiLimiter {
    $m = $null
    try { $m = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" }
    $cap = if ($m) { Get-JuicerFpsCap ([int]$m.Display.Hz) (Resolve-JuicerMonitorUse $m) $null $(if ($m.Vrr) { [int]$m.Vrr.Min } else { 0 }) } else { $null }
    @{
        Backend = (Get-JuicerFpsBackend); Monitor = $(if ($m) { Format-JuicerMonitor $m } else { '' }); Cap = $cap
        Mode = $(if ($m) { $m.Mode } else { '' })
        Limits = @(Get-JuicerFpsLimits)
    }
}

# The choices are there from the start; which one is yours arrives with the
# monitor, read in the background.
function Initialize-JuicerGuiMonitorModes {
    $c = $script:Gui.C
    if ($c.MonitorMode.Items.Count -gt 0) { return }
    $modes = Get-JuicerMonitorModes
    foreach ($k in $modes.Keys) { [void]$c.MonitorMode.Items.Add((New-JuicerUi ComboBoxItem @{ Content = $modes[$k]; Tag = $k })) }
    $c.MonitorMode.IsEnabled = $false
}

function Show-JuicerGuiLimiter {
    param([hashtable]$L)
    if (-not $L) { return }
    $c = $script:Gui.C
    $lines = @("Limita con: $(Format-JuicerFpsBackend $L.Backend).")
    if ($L.Monitor) { $lines += "Tu pantalla: $($L.Monitor)." }
    if ($L.Cap) { $lines += "Límite recomendado: $($L.Cap.Fps) FPS. $($L.Cap.Why) Si mediste un juego y sus frametimes oscilan, a ese juego le pone el que sostiene." }
    $c.LimitNote.Text = $lines -join ' '
    # Filling the list or choosing the saved mode is not the user changing it.
    $script:Gui.SettingMode = $true
    try {
        Initialize-JuicerGuiMonitorModes
        $c.MonitorMode.IsEnabled = [bool]$L.Mode
        foreach ($it in $c.MonitorMode.Items) { if ([string]$it.Tag -eq [string]$L.Mode) { $c.MonitorMode.SelectedItem = $it } }
    } finally {
        $script:Gui.SettingMode = $false
    }
    $c.BtnLimitRecalc.IsEnabled = @($L.Limits).Count -gt 0
}

function Start-JuicerGuiLimiter {
    param([string[]]$Add = @(), [string[]]$Remove = @(), [switch]$Recalc)
    Start-JuicerGuiTask 'Aplicando el limitador…' 'Limiter' @{ Add = $Add; Remove = $Remove; Fps = 0; Recalc = [bool]$Recalc } {
        param($r)
        Show-JuicerGuiLimiter $r.Limiter
        $bad = @($r.Results | Where-Object { $_.Outcome -in 'Error', 'NoAplica' })
        if ($bad.Count -gt 0) { Show-JuicerGuiMessage (($bad | ForEach-Object { '{0}: {1}' -f $_.Title, $_.Message }) -join "`n") 'Warning' | Out-Null }
        Show-JuicerGuiUndo
        Set-JuicerGuiStatus 'Limitador actualizado: se aplica solo cada vez que abras esos juegos.'
        if ($script:Gui.GamesLoaded) { Start-JuicerGuiGameSetup 'Refresh' }
    }
}

function Show-JuicerGuiGames {
    param([object[]]$Libraries)
    $c = $script:Gui.C
    $c.LibPanel.Children.Clear()
    foreach ($l in @($Libraries)) {
        $done = $l.State -eq 'Aplicado'
        $label = '{0}: {1}{2}' -f $l.Launcher, $l.Path, $(if ($done) { '  ✓ ya excluida' } else { '' })
        $cb = New-JuicerUi CheckBox @{ Content = $label; Tag = @{ Path = $l.Path; Launcher = $l.Launcher }; IsEnabled = -not $done }
        [void]$c.LibPanel.Children.Add($cb)
    }
    if (@($Libraries).Count -eq 0) {
        [void]$c.LibPanel.Children.Add((New-JuicerUi TextBlock @{ Text = 'No he encontrado bibliotecas de Steam, Epic, GOG ni Xbox. Puedes añadir otra carpeta.'; Foreground = '#9A9AA5'; TextWrapping = 'Wrap' }))
    }
}

function Start-JuicerGuiStartupList {
    Start-JuicerGuiTask 'Leyendo los programas de inicio…' 'Startup' @{} { param($r) Show-JuicerGuiStartup $r.Items }
}

function Get-JuicerCheckedTags {
    param([hashtable]$Checks)
    @(foreach ($k in $Checks.Keys) {
            $e = $Checks[$k]
            $cb = if ($e -is [hashtable]) { $e.Check } else { $e }
            if ($cb.IsChecked -and $cb.IsEnabled -and $cb.Visibility -eq 'Visible') { $k }
        })
}

function Register-JuicerGuiHandlers {
    $c = $script:Gui.C
    $h = @{
        BtnAudit              = { Start-JuicerGuiAudit }
        BtnMeasure            = { Start-JuicerGuiMeasure $false }
        BtnFineSave           = {
            $c = $script:Gui.C
            $cpu = ([string]$c.FineCpu.Text).Trim(); $gpu = ([string]$c.FineGpu.Text).Trim()
            if (-not $cpu -and -not $gpu) { Show-JuicerGuiMessage 'Escribe qué has aplicado al procesador, a la gráfica o a los dos.' | Out-Null; return }
            $tool = if ($c.FineGpuTool.SelectedItem) { [string]$c.FineGpuTool.SelectedItem.Tag } else { '' }
            Start-JuicerGuiFineTune @{ Save = $true; Cpu = $cpu; Gpu = $gpu; Tool = $tool; Watch = [bool]$c.FineWatch.IsChecked }
        }
        BtnFineForget         = {
            if (-not (Confirm-JuicerGui '¿Olvidar tu ajuste apuntado y dejar de comprobarlo al iniciar sesión? No cambia nada en la BIOS ni en la gráfica.')) { return }
            Start-JuicerGuiFineTune @{ Forget = $true }
        }
        BtnFrameMeasure       = {
            $item = $script:Gui.C.FrameSeconds.SelectedItem
            $secs = if ($item) { [int]$item.Tag } else { 60 }
            Start-JuicerGuiTask 'Preparando la medida…' 'Frames' @{ Seconds = $secs } {
                param($r)
                $p = $script:Gui.C.FramePanel
                $p.Children.Clear()
                foreach ($f in @($r.Findings)) { [void]$p.Children.Add((New-JuicerFindingCard $f)) }
                Set-JuicerGuiStatus 'Medida terminada: el resultado está en la pestaña Juegos.'
            }
        }
        BtnMeasureReset       = {
            if (-not (Confirm-JuicerGui '¿Empezar la comparación desde ahora? La medida inicial anterior se descarta.')) { return }
            Start-JuicerGuiMeasure $true
        }
        BtnUpdateCopy         = {
            ('System.Windows.Clipboard' -as [type])::SetText($script:OneLineCommand)
            Set-JuicerGuiStatus 'Orden copiada. Cierra Win Juicer, abre PowerShell y pégala.'
        }
        BtnAuditSave          = {
            if (@($script:Gui.Findings).Count -eq 0) { Show-JuicerGuiMessage 'El diagnóstico todavía no ha terminado.' | Out-Null; return }
            $p = Save-JuicerAuditReport '' (Format-JuicerHardwareSummary $script:Gui.Hw) $script:Gui.Findings
            Show-JuicerGuiMessage "Informe guardado en el escritorio:`n$p" | Out-Null
        }
        BtnLibRefresh         = { Start-JuicerGuiGames }
        BtnLimitRecalc        = { Start-JuicerGuiLimiter -Recalc }
        BtnGamesOptimize      = { Start-JuicerGuiGameSetup 'Recomendado' }
        BtnGamesLimit         = { Start-JuicerGuiGameSetup 'Fps' }
        BtnGamesGpu           = { Start-JuicerGuiGameSetup 'Gpu' }
        BtnGamesPrio          = { Start-JuicerGuiGameSetup 'Prioridad' }
        BtnGamesClear         = { Start-JuicerGuiGameSetup 'Quitar' }
        BtnGamesAll           = { Set-JuicerGuiGameChecks $true }
        BtnGamesNone          = { Set-JuicerGuiGameChecks $false }
        BtnGamesRefresh       = { Start-JuicerGuiGameSetup 'Refresh' }
        BtnGamesAdd           = {
            $d = New-Object Microsoft.Win32.OpenFileDialog
            $d.Filter = 'Juegos (*.exe)|*.exe'
            if ($d.ShowDialog()) { Start-JuicerGuiGameSetup 'Add' @{ Exe = $d.FileName } }
        }
        BtnLibFolder          = {
            Add-Type -AssemblyName System.Windows.Forms
            $d = ('System.Windows.Forms.FolderBrowserDialog' -as [type])::new()
            $d.Description = 'Carpeta de juegos que Defender no debe analizar al abrir'
            if ($d.ShowDialog() -eq 'OK') {
                $cb = New-JuicerUi CheckBox @{ Content = $d.SelectedPath; Tag = @{ Path = $d.SelectedPath; Launcher = '' }; IsChecked = $true }
                [void]$script:Gui.C.LibPanel.Children.Add($cb)
            }
        }
        BtnLibAdd             = {
            $sel = @($script:Gui.C.LibPanel.Children | Where-Object { $_.IsChecked -and $_.IsEnabled -and $_.Tag -is [hashtable] } | ForEach-Object { $_.Tag })
            if ($sel.Count -eq 0) { Show-JuicerGuiMessage 'No hay ninguna carpeta seleccionada.' | Out-Null; return }
            $list = ($sel | ForEach-Object { '· ' + $_.Path }) -join "`n"
            if (-not (Confirm-JuicerGui "EXTREMO: Defender dejará de analizar al abrirse los archivos de:`n`n$list`n`nUn archivo malicioso ahí dentro no se detectaría al abrirse. ¿Seguir?" 'Warning')) { return }
            $games = @($sel | ForEach-Object { @{ Kind = 'defender'; Path = $_.Path; Launcher = $_.Launcher } })
            Start-JuicerGuiTask 'Añadiendo exclusiones…' 'Run' @{ Games = $games } { param($r) Complete-JuicerGuiRun $r; Start-JuicerGuiGames }
        }
        BtnAuditRecommended   = {
            $ids = Get-JuicerSelection 'Recomendado' @(Get-JuicerCatalog) $script:Gui.Snapshot.States $script:Gui.Advice
            if ($ids.Count -eq 0) { Show-JuicerGuiMessage 'Ya tienes aplicado todo lo recomendado para este equipo.' | Out-Null; return }
            Invoke-JuicerGuiApply $ids
        }
        BtnSelRecomendado     = { Select-JuicerGuiTweaks 'Recomendado' }
        BtnSelSeguro          = { Select-JuicerGuiTweaks 'Seguro' }
        BtnSelRendimiento     = { Select-JuicerGuiTweaks 'Rendimiento' }
        BtnSelExtremo         = { Select-JuicerGuiTweaks 'Extremo' }
        BtnSelNinguno         = { Select-JuicerGuiTweaks 'Ninguno' }
        BtnApply              = { Invoke-JuicerGuiApply (Get-JuicerCheckedTags $script:Gui.Checks) }
        BtnSimulate           = { Invoke-JuicerGuiApply (Get-JuicerCheckedTags $script:Gui.Checks) -Simulate }
        BtnUndoSelected       = {
            $ids = @(Get-JuicerCheckedTags $script:Gui.Checks | Where-Object { $script:Gui.Snapshot.States[$_].Undoable })
            if ($ids.Count -eq 0) { Show-JuicerGuiMessage 'Ninguno de los seleccionados lo cambió Win Juicer: no hay nada que deshacer.' | Out-Null; return }
            Start-JuicerGuiTask 'Deshaciendo…' 'Run' @{ Undo = $ids } { param($r) Complete-JuicerGuiRun $r }
        }
        BtnExport             = {
            $d = New-Object Microsoft.Win32.SaveFileDialog
            $d.Filter = 'Configuración de Win Juicer (*.json)|*.json'
            $d.FileName = 'winjuicer-config.json'
            if (-not $d.ShowDialog($script:Gui.Window)) { return }
            $cfg = Export-JuicerConfig $d.FileName
            $n = @($cfg.Tweaks).Count + $cfg.Toggles.Count + @($cfg.Apps).Count + $(if ($cfg.Dns) { 1 } else { 0 })
            if ($n -eq 0) { Show-JuicerGuiMessage 'Guardado, pero vacío: Win Juicer todavía no ha cambiado nada en este equipo.' | Out-Null; return }
            Show-JuicerGuiMessage "Guardado en $($d.FileName):`n`n$(Format-JuicerConfigSummary (Read-JuicerConfig $d.FileName))`n`nEn el otro equipo, Importar lo aplica. Programas de inicio y ajustes de juegos no se exportan: son de este PC." | Out-Null
        }
        BtnImport             = {
            $d = New-Object Microsoft.Win32.OpenFileDialog
            $d.Filter = 'Configuración de Win Juicer (*.json)|*.json'
            if (-not $d.ShowDialog($script:Gui.Window)) { return }
            $cfg = Read-JuicerConfig $d.FileName
            $n = @($cfg.Tweaks).Count + $cfg.Toggles.Count + @($cfg.Apps).Count + $(if ($cfg.Dns) { 1 } else { 0 })
            if ($n -eq 0) { Show-JuicerGuiMessage "No hay nada que aplicar en $($d.FileName)." | Out-Null; return }
            $risky = @(@($cfg.Tweaks | ForEach-Object { Find-JuicerTweak $_ } | Where-Object { $_.Level -ge 3 } | ForEach-Object { $_.Title }) +
                @($cfg.Apps | ForEach-Object { Find-JuicerDebloatApp $_ } | Where-Object { $_.Class -eq 'Cuidado' } | ForEach-Object { 'Quitar ' + $_.Title }))
            $text = "Se aplicará:`n`n$(Format-JuicerConfigSummary $cfg)"
            if ($risky.Count -gt 0) { $text += "`n`nIncluye cosas del nivel Extremo o con cuidado: $($risky -join ', '). Lee qué cuestan en Ajustes antes de seguir." }
            $text += "`n`nLo que no aplique en este equipo se saltará solo. ¿Seguir?"
            if (-not (Confirm-JuicerGui $text $(if ($risky.Count) { 'Warning' } else { 'Question' }))) { return }
            $toggles = @($cfg.Toggles.Keys | ForEach-Object { @{ Id = $_; On = [bool]$cfg.Toggles[$_] } })
            Start-JuicerGuiTask 'Aplicando la configuración importada…' 'Run' @{
                Ids = $cfg.Tweaks; Apps = $cfg.Apps; Dns = $cfg.Dns; Toggles = $toggles; RestorePoint = [bool]$script:Gui.C.ChkRestorePoint.IsChecked
            } { param($r) Complete-JuicerGuiRun $r }
        }
        BtnPlanAdd            = { if ($script:Gui.PlanId) { Invoke-JuicerGuiApply @($script:Gui.PlanId) } }
        BtnPlanRemove         = {
            $id = $script:Gui.PlanId
            if (-not $id -or -not (Get-JuicerJournalEntry (Read-JuicerJournal) $id)) { Show-JuicerGuiMessage 'Win Juicer no ha cambiado el plan de energía: no hay nada que quitar.' | Out-Null; return }
            Start-JuicerGuiTask 'Quitando el plan…' 'Run' @{ Undo = @($id) } { param($r) Complete-JuicerGuiRun $r }
        }
        BtnDns                = {
            $item = $script:Gui.C.DnsCombo.SelectedItem
            if (-not $item) { return }
            Start-JuicerGuiTask 'Cambiando el DNS…' 'Run' @{ Dns = [string]$item.Tag } { param($r) Complete-JuicerGuiRun $r }
        }
        BtnDnsUndo            = { Start-JuicerGuiTask 'Devolviendo el DNS…' 'Run' @{ Undo = @('red.dns') } { param($r) Complete-JuicerGuiRun $r } }
        BtnDebloatRecommended = { foreach ($e in $script:Gui.AppChecks.Values) { if ($e.App) { $e.Check.IsChecked = [bool]$e.App.Recommended } } }
        BtnDebloatNone        = { foreach ($e in $script:Gui.AppChecks.Values) { $e.Check.IsChecked = $false } }
        BtnDebloatRefresh     = { Start-JuicerGuiDebloat }
        BtnDebloatReinstall   = { Show-JuicerGuiUndo; $script:Gui.C.Tabs.SelectedItem = $script:Gui.C.TabDeshacer }
        BtnDebloatRemove      = {
            $tags = Get-JuicerCheckedTags $script:Gui.AppChecks
            if ($tags.Count -eq 0) { Show-JuicerGuiMessage 'No hay ninguna app seleccionada.' | Out-Null; return }
            $apps = @($tags | Where-Object { $script:Gui.AppChecks[$_].App })
            $ids = @($tags | Where-Object { $script:Gui.AppChecks[$_].Tweak })
            $warn = @($apps | Where-Object { $script:Gui.AppChecks[$_].App.Need } | ForEach-Object { "· $($script:Gui.AppChecks[$_].App.Title): $($script:Gui.AppChecks[$_].App.Need)" })
            $careful = @($apps | Where-Object { $script:Gui.AppChecks[$_].App.Class -eq 'Cuidado' } | ForEach-Object { "· $($script:Gui.AppChecks[$_].App.Title): $($script:Gui.AppChecks[$_].App.What)" })
            $text = "Se quitará:`n`n" + (@($tags | ForEach-Object { if ($script:Gui.AppChecks[$_].App) { '· ' + $script:Gui.AppChecks[$_].App.Title } else { '· ' + $script:Gui.AppChecks[$_].Tweak.Title } }) -join "`n")
            if ($careful.Count -gt 0) { $text += "`n`nCon cuidado:`n" + ($careful -join "`n") }
            if ($warn.Count -gt 0) { $text += "`n`nTu equipo las usa:`n" + ($warn -join "`n") }
            if (-not (Confirm-JuicerGui "$text`n`n¿Seguir?" $(if ($warn.Count -or $careful.Count) { 'Warning' } else { 'Question' }))) { return }
            Start-JuicerGuiTask 'Quitando apps…' 'Run' @{ Apps = $apps; Ids = $ids; RestorePoint = [bool]$script:Gui.C.ChkRestorePoint.IsChecked } { param($r) Complete-JuicerGuiRun $r }
        }
        BtnInstallSuggested   = { foreach ($e in $script:Gui.InstallChecks.Values) { $e.Check.IsChecked = ($e.Suggested -and -not $e.Installed) } }
        BtnInstallNone        = { foreach ($e in $script:Gui.InstallChecks.Values) { $e.Check.IsChecked = $false } }
        BtnInstall            = { Invoke-JuicerGuiWinget 'install' }
        BtnUninstall          = { Invoke-JuicerGuiWinget 'uninstall' }
        BtnUpgradeAll         = { Invoke-JuicerGuiWinget 'upgrade' }
        BtnInstalledRefresh   = { Start-JuicerGuiInstalled }
        BtnStartupRefresh     = { Start-JuicerGuiStartupList }
        BtnStartupJunk        = {
            $junk = @($script:Gui.Startup | Where-Object { $_.Enabled -and $_.Verdict -eq 'Prescindible' })
            if ($junk.Count -eq 0) { Show-JuicerGuiMessage 'No hay nada prescindible arrancando con Windows.' | Out-Null; return }
            $list = ($junk | ForEach-Object { "· $($_.Name): $($_.Why)" }) -join "`n"
            if (-not (Confirm-JuicerGui "Dejarán de arrancar con Windows (no se desinstala nada):`n`n$list`n`n¿Seguir?")) { return }
            Start-JuicerGuiTask 'Desactivando programas de inicio…' 'Startup' @{ Disable = $junk } {
                param($r)
                Show-JuicerGuiStartup $r.Items
                Show-JuicerGuiResults $r.Results
                Show-JuicerGuiUndo
            }
        }
        BtnCleanup            = { Start-JuicerModuleWindow 'Invoke-JuicerCleanup' 'Win Juicer: limpieza' }
        BtnOptimize           = { Start-JuicerModuleWindow 'Invoke-JuicerDriveOptimize' 'Win Juicer: optimizar unidades' }
        BtnComponents         = { Start-JuicerModuleWindow 'Invoke-JuicerComponentCleanup' 'Win Juicer: limpiar componentes' }
        BtnRepair             = { Start-JuicerModuleWindow 'Invoke-JuicerSystemRepair' 'Win Juicer: reparar Windows' }
        BtnNetReset           = {
            if (Confirm-JuicerGui 'Restablece Winsock y TCP/IP: arregla «conectado, sin internet» que dejan VPN y cortafuegos antiguos. Hay que reiniciar después. ¿Seguir?') {
                Start-JuicerModuleWindow 'Invoke-JuicerNetworkReset' 'Win Juicer: restablecer la red'
            }
        }
        BtnWuReset            = {
            if (Confirm-JuicerGui 'Detiene Windows Update, aparta su caché (renombrada, no borrada) y lo vuelve a arrancar. Para cuando se atasca o falla siempre igual. ¿Seguir?') {
                Start-JuicerModuleWindow 'Invoke-JuicerUpdateReset' 'Win Juicer: restablecer Windows Update'
            }
        }
        BtnRestorePoint       = { Start-JuicerGuiTask 'Creando punto de restauración…' 'Restore' @{} { param($r) Show-JuicerGuiMessage $r.Rp.Message | Out-Null } }
        BtnUndoChecked        = {
            $ids = Get-JuicerCheckedTags $script:Gui.UndoChecks
            if ($ids.Count -eq 0) { return }
            Start-JuicerGuiTask 'Deshaciendo…' 'Run' @{ Undo = $ids } { param($r) Complete-JuicerGuiRun $r }
        }
        BtnUndoAll            = {
            $journal = Read-JuicerJournal
            if ($journal.Count -eq 0) { return }
            if (-not (Confirm-JuicerGui "¿Deshacer los $($journal.Count) cambios de Win Juicer?")) { return }
            $ids = @($journal | ForEach-Object { $_.Id })
            [array]::Reverse($ids)
            Start-JuicerGuiTask 'Deshaciendo todo…' 'Run' @{ Undo = $ids } { param($r) Complete-JuicerGuiRun $r }
        }
    }
    $script:Gui.Handlers = $h
    foreach ($name in $h.Keys) {
        $c[$name].Add_Click({
                try {
                    & $script:Gui.Handlers[$this.Name]
                } catch {
                    Write-JuicerLog "Error en $($this.Name): $_"
                    Show-JuicerGuiMessage "Algo falló: $_" 'Error' | Out-Null
                }
            })
    }
    $c.SearchBox.Add_TextChanged({ Set-JuicerGuiSearch })
    $c.MonitorMode.Add_SelectionChanged({
            if ($script:Gui.SettingMode) { return }
            $item = $script:Gui.C.MonitorMode.SelectedItem
            if (-not $item) { return }
            Start-JuicerGuiTask 'Guardando cómo usas el monitor…' 'MonitorMode' @{ Mode = [string]$item.Tag } {
                param($r)
                Show-JuicerGuiLimiter $r.Limiter
                if (@($r.Limiter.Limits).Count -gt 0 -and (Confirm-JuicerGui '¿Recalcular con este modo los límites de los juegos que ya tienes limitados?')) {
                    Start-JuicerGuiLimiter -Recalc
                } else {
                    Set-JuicerGuiStatus 'Guardado. Los juegos que limites a partir de ahora usarán este modo.'
                }
            }
        })
    $c.Tabs.Add_SelectionChanged({
            # $_ is the event: the ComboBox inside a tab raises it too.
            if ($_.OriginalSource -ne $script:Gui.C.Tabs -or -not $script:Gui.Ready) { return }
            $tab = $script:Gui.C.Tabs.SelectedItem
            if ($tab -eq $script:Gui.C.TabDebloat -and -not $script:Gui.DebloatLoaded) { Start-JuicerGuiDebloat }
            elseif ($tab -eq $script:Gui.C.TabInstalar -and $null -eq $script:Gui.Installed) { Start-JuicerGuiInstalled }
            elseif ($tab -eq $script:Gui.C.TabInicio -and -not $script:Gui.StartupLoaded) { $script:Gui.StartupLoaded = $true; Start-JuicerGuiStartupList }
            elseif ($tab -eq $script:Gui.C.TabJuegos -and -not $script:Gui.GamesLoaded) { $script:Gui.GamesLoaded = $true; Start-JuicerGuiGames }
            elseif ($tab -eq $script:Gui.C.TabAjusteFino -and -not $script:Gui.FineLoaded) { $script:Gui.FineLoaded = $true; Start-JuicerGuiFineTune }
            elseif ($tab -eq $script:Gui.C.TabDeshacer) { Show-JuicerGuiUndo }
        })
}

function Select-JuicerGuiTweaks {
    param([string]$Mode)
    $ids = Get-JuicerSelection $Mode @(Get-JuicerCatalog) $script:Gui.Snapshot.States $script:Gui.Advice
    foreach ($k in $script:Gui.Checks.Keys) {
        $cb = $script:Gui.Checks[$k]
        if ($cb.IsEnabled) { $cb.IsChecked = ($ids -contains $k) }
    }
    $label = @{ Recomendado = 'lo recomendado para este equipo'; Seguro = 'el perfil Seguro'; Rendimiento = 'el perfil Rendimiento'; Extremo = 'el perfil Extremo' }[$Mode]
    if ($label) { Set-JuicerGuiStatus "Seleccionado ${label}: $($ids.Count) ajustes por aplicar." } else { Set-JuicerGuiStatus 'Selección vacía.' }
}

function Invoke-JuicerGuiWinget {
    param([string]$Action)
    if (-not (Test-JuicerWinget)) { Show-JuicerGuiMessage 'winget no está disponible. Instala o actualiza «Instalador de aplicación» desde Microsoft Store.' 'Warning' | Out-Null; return }
    $ids = @()
    if ($Action -ne 'upgrade') {
        $ids = Get-JuicerCheckedTags $script:Gui.InstallChecks
        if ($ids.Count -eq 0) { Show-JuicerGuiMessage 'No hay ningún programa seleccionado.' | Out-Null; return }
        if ($Action -eq 'uninstall' -and -not (Confirm-JuicerGui ("Se desinstalará:`n`n" + (($ids | ForEach-Object { '· ' + $script:Gui.InstallChecks[$_].App.Name }) -join "`n") + "`n`n¿Seguir?"))) { return }
    }
    Start-JuicerWinget $Action $ids
    Set-JuicerGuiStatus 'winget trabaja en su propia ventana. Cuando acabe, pulsa «Ver lo instalado».'
}

function Complete-JuicerGuiInit {
    param([hashtable]$R)
    $script:Gui.Hw = $R.Hw
    $script:Gui.Advice = $R.Advice
    $script:Gui.Snapshot = $R.Snapshot
    $summary = @(Format-JuicerHardwareSummary $R.Hw)
    $script:Gui.C.HwLine.Text = (@($summary | Select-Object -First 2) -join '   ·   ')
    $script:Gui.C.HwLine.ToolTip = New-JuicerTip $summary
    if ($R.Update) {
        $script:Gui.C.UpdateNote.Text = "Hay una versión nueva ($($R.Update.Latest)); tienes la $($R.Update.Local)."
        $script:Gui.C.UpdatePanel.ToolTip = $R.Update.Command
        $script:Gui.C.UpdatePanel.Visibility = 'Visible'
    }
    Show-JuicerGuiTweaks
    Show-JuicerGuiApps
    Show-JuicerGuiUndo
    $script:Gui.Ready = $true
    Set-JuicerGuiStatus 'Listo. El diagnóstico completo está en marcha.'
    Start-JuicerGuiAudit
}

# Builds the window and its controls. -NoShow returns it without opening it:
# the tests draw every tab with real controls and close it.
function Show-JuicerGui {
    param([switch]$NoShow)
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$script:GuiXaml)
    $win = ('System.Windows.Markup.XamlReader' -as [type])::Load($reader)
    $script:Gui = @{
        Window = $win; C = @{}; Sync = [hashtable]::Synchronized(@{ Status = '' }); Task = $null
        Checks = @{}; AppChecks = @{}; InstallChecks = @{}; UndoChecks = @{}
        Hw = @{ Cpu = @{}; Gpus = @() }; Advice = @{}; Snapshot = @{ States = @{}; Dns = @() }
        Installed = $null; Ready = $false; DebloatLoaded = $false; StartupLoaded = $false; GamesLoaded = $false; FineLoaded = $false; Findings = @(); Measure = @()
        Queue = (New-Object System.Collections.ArrayList)
    }
    foreach ($n in (Get-JuicerGuiNames)) { $script:Gui.C[$n] = $win.FindName($n) }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({ Complete-JuicerGuiTask })
    $script:Gui.Timer = $timer
    Register-JuicerGuiHandlers
    Initialize-JuicerGuiMonitorModes
    Show-JuicerGuiMyths
    Show-JuicerGuiUndo
    if ($NoShow) {
        $script:Gui.Silent = New-Object System.Collections.ArrayList
        return $script:Gui
    }
    $win.Add_ContentRendered({ Start-JuicerGuiTask 'Leyendo el equipo…' 'Init' @{} { param($r) Complete-JuicerGuiInit $r } })
    # Closing kills the background runspace: never in the middle of a change.
    $win.Add_Closing({
            $t = $script:Gui.Task
            if ($t -and $t.Work -eq 'Run' -and -not $t.Handle.IsCompleted) {
                $_.Cancel = $true
                Show-JuicerGuiMessage 'Win Juicer está aplicando cambios. Espera a que termine para cerrar: cortarlo a medias dejaría el cambio en curso a medio hacer.' 'Warning' | Out-Null
            }
        })
    [void]$win.ShowDialog()
}
