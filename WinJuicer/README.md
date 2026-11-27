# Win Juicer

Exprime Windows 10 y 11 para jugar y para cargar rápido, sin humo y con vuelta atrás.

Funciona en **Windows 10 (22H2, compilación 19045) y en Windows 11**. Algunos
ajustes sólo existen en Windows 11 (el menú contextual clásico, la barra de
tareas a la izquierda, Copilot, Recall, la galería del Explorador…): en Windows 10
salen como **no aplica**, con el motivo, y no se escribe nada. Otros se explican
distinto según la versión («Noticias e intereses» en Windows 10, Widgets en
Windows 11) y alguno hace más cosas en Windows 10 (la búsqueda de Inicio).

La mayoría de «optimizadores» son una lista de claves de registro copiadas de
foros: la mitad no hace nada y la otra mitad rompe algo. Win Juicer hace lo
contrario. Cada ajuste dice **qué hace, qué ganas y qué te cuesta**, en ese
orden y sin adornos; ninguno se aplica sin que lo veas; y **todo se puede
deshacer**, uno a uno o de golpe, porque antes de tocar nada guarda cómo
estaba.

La ventana se inspira en la [WinUtil de Chris Titus](https://github.com/ChrisTitusTech/winutil):
pestañas, casillas, botones de «selección recomendada», interruptores de
preferencias, plan de máximo rendimiento, DNS, debloat e instalación con
winget. La diferencia está en lo que hay detrás: **lo recomendado lo decide el
hardware de tu equipo**, no un perfil genérico de «sobremesa» o «portátil», y
cada cambio va a un diario que lo puede deshacer.

---

## Lo primero: lo que ningún programa puede arreglar

Las mayores pérdidas de rendimiento de un PC para juegos casi nunca están en el
registro de Windows. Están aquí:

- **La RAM sin su perfil XMP/EXPO.** Un kit DDR4-3600 funcionando a 2133, o un
  DDR5-6000 a 4800. Se activa en la BIOS.
- **Un solo módulo de RAM, o dos en el mismo canal.** La mitad de ancho de banda.
- **Un monitor de 144 Hz funcionando a 60.** Pasa muchísimo, y se arregla en
  Configuración en diez segundos. O por debajo de su resolución nativa.
- **Auriculares Bluetooth para jugar**: el audio llega entre 100 y 300 ms tarde.
  Cable, USB o receptor de 2,4 GHz (ver **Audio**).
- **El monitor enchufado a la placa base** en vez de a la tarjeta gráfica.
- **Windows o la biblioteca de juegos en un disco duro mecánico.** Ningún ajuste
  compensa eso.
- **Un portátil jugando con batería**, o sin la gráfica dedicada.
- **Resizable BAR apagado** en la BIOS.
- **Una BIOS con un fallo conocido**, o un overclock que ya está dando errores.

Por eso lo primero que hace Win Juicer es un **diagnóstico** que no cambia nada
y que busca exactamente eso, y te dice por orden qué merece la pena arreglar.

## Cómo se usa

**En una línea**, como WinUtil: abre PowerShell y pega

```powershell
irm https://github.com/Chomp-wq/BtJuicer/releases/download/winjuicer/winjuicer.ps1 | iex
```

Descarga la última versión, comprueba que el zip es exactamente el publicado
(SHA256) y la abre como administrador. Se descarga y comprueba en cada
arranque, así que no queda nada guardado que alguien pudiera cambiar para que
se ejecute como administrador la próxima vez. Lo que se ejecuta como
administrador nunca sale de una carpeta que un usuario normal pueda escribir:
el zip baja a `%TEMP%`, pero el proceso ya elevado lo copia a una carpeta de
`Archivos de programa` (`WinJuicer-descarga`), vuelve a calcular su SHA256 sobre
esa copia y sólo entonces lo descomprime y lo ejecuta; si alguien cambia el zip
entre medias, no coincide y no se ejecuta nada. Si cancelas la ventana de
permisos (UAC) lo dice y borra lo descargado, y la descarga tiene tiempo máximo. Las carpetas de versiones anteriores sólo se borran pasados 7 días. La release la publica el CI
desde la rama principal, con todas las pruebas en verde.

**O sin internet**: descarga la carpeta `WinJuicer` (o el `WinJuicer.zip` de la
release) y haz doble clic en **`WinJuicer.cmd`**. Pide permisos de
administrador y abre la ventana. Una copia descargada de la release sabe qué
versión es: al abrirse mira si hay otra más nueva (lee la versión del
arrancador publicado, 3 KB, nada más) y, si la hay, lo dice arriba con dos
botones: **Actualizar ahora** y «Copiar la orden». Actualizar ahora **pregunta
antes**, enseña la orden y, si dices que sí, abre una PowerShell nueva que
ejecuta exactamente esa orden publicada, la que comprueba el SHA256 (ver arriba),
y cierra Win Juicer; no actualiza nunca en silencio, y sólo acepta una orden con
la forma de la publicada. En el menú de la consola es la opción **A**, con la
misma pregunta.

La ventana empieza **sencilla**, para que cualquiera pueda usarla: la pestaña
**Empezar** tiene cuatro botones grandes, en palabras normales:
- **Optimizar Windows**: aplica sólo lo que conviene a tu equipo (nada del
  nivel Extremo), con un punto de restauración antes. Una pregunta y listo: la
  pregunta lista los ajustes (los ocho primeros y «y N más»), marca los que
  necesitan reiniciar o volver a entrar y lo dice una vez al final.
- **Mis juegos**: la galería de tus juegos (abajo).
- **Revisar mi PC**: el diagnóstico, con cuántas cosas conviene arreglar.
- **Deshacer**: todo lo que ha hecho Win Juicer, de golpe. Antes enseña qué
  se va a revertir (los ocho primeros y «y N más») y lo que no puede deshacer
  y se queda: la protección contra contenido adulto, la limpieza y el resto de
  Mantenimiento, los programas instalados con winget y los puntos de
  restauración. Las apps quitadas se reinstalan desde Microsoft Store (con
  internet).

Con eso, más **Equipo**, **Juegos** y **Deshacer**, no hace falta nada más.

Debajo, **Protección contra contenido adulto**: opcional y para siempre (ver
más abajo).

**Modo avanzado**, la casilla de arriba a la derecha, es para quien sabe lo que
toca: añade el resto de pestañas y abre **Ajustes**, donde eliges una a una las
optimizaciones. Se recuerda para la próxima vez.
- Cada ajuste dice de un vistazo su nivel (seguro, rendimiento, extremo), si
  pide reiniciar o volver a entrar, si está aplicado y si conviene a tu equipo (★).
- **Buscar** por nombre, por lo que hace o por su identificador; filtrar por
  **nivel** y por **estado** (sin aplicar, aplicados, recomendados para tu
  equipo, sólo los seleccionados). Los filtros cambian lo que ves, no lo que has
  elegido: «Aplicar» aplica todo lo seleccionado, se vea o no.
- **todos / ninguno** en cada categoría, y la cuenta de seleccionados en el
  botón de aplicar. Aplicar, simular y deshacer van debajo de la lista,
  siempre a la vista.
- **Detalles**, a la derecha, del ajuste que tengas bajo el ratón: qué hace,
  qué ganas, qué cuesta, su estado, si conviene a tu equipo y por qué, y **qué
  cambia exactamente**: cada valor del registro, servicio o tarea, tal como lo
  escribirá. Y su identificador, para `-Aplicar` y `-Deshacer`.
- **Simular** dice qué cambiaría todo lo seleccionado, sin cambiar nada.
- En **Perfiles**, a la derecha: **Guardar selección…** guarda lo que has
  marcado como perfil propio; **Cargar selección…** lo vuelve a marcar (aquí o
  en otro PC) sin aplicar nada, para revisarlo antes. **Importar…** te enseña
  lo que va a aplicar y lo aplica si dices que sí. Pregunta una a una lo mismo
  que al aplicar o quitar a mano: cada ajuste Extremo y cada app «con cuidado»
  se confirman por separado, y las apps que tu equipo usa (Xbox con Game Pass,
  la Game Bar en un Ryzen X3D de dos CCD…) se saltan y lo dice.

Las pestañas:

| Pestaña | Qué tiene |
|---|---|
| **Empezar** | Los cuatro botones de arriba, con el estado de cada cosa; «Listo para jugar» (abajo) y, sólo si Windows ha deshecho algo tuyo, «Qué ha cambiado». |
| **Equipo** | El hardware detectado y el diagnóstico completo, BIOS y overclock incluidos. Botones «Aplicar lo recomendado para este equipo», «Guardar informe» (un .txt en el escritorio, para guardarlo o pedir ayuda en un foro) y «Medir antes y después». |
| **Ajustes** | Todos los ajustes en una lista, para elegirlos uno a uno (arriba). Selección rápida: *Para este equipo* · *Seguro* · *Rendimiento* · *Extremo*. A la derecha, los detalles del ajuste; las preferencias (tema oscuro, extensiones…), el plan de máximo rendimiento y el DNS; y los perfiles: guardar y cargar tu selección, y *Exportar lo aplicado…* e *Importar…* para llevar tu configuración a otro PC. |
| **Debloat** | Las apps que vienen con Windows y siguen instaladas, una a una, con lo que es cada una. |
| **Instalar** | Programas habituales con winget: lanzadores de juegos, navegadores, herramientas de hardware. |
| **Arranque** | Lo que arranca solo con Windows, con el mismo interruptor del Administrador de tareas, y qué es cada cosa: prescindible, opcional o necesaria. Botón para desactivar de golpe los prescindibles. Junto a cada uno, los segundos que Windows midió que retrasó el arranque (abajo). |
| **Juegos** | La galería de tus juegos, con sus portadas, que encuentra solo. «Optimizar todos» en un clic, o pulsa un juego para su página: frame pacer (fluidez o latencia, ritmo automático o el tuyo, calibrar), gráfica potente, prioridad por encima de lo normal, modo prudente, medir FPS y frametimes, y qué poner dentro del juego. En «Mi pantalla y el frame pacer…», cómo usas el monitor, el motor y, con todas las opciones, medir cualquier juego y las exclusiones de Defender. |
| **Mantenimiento** | Limpieza, TRIM, DISM y SFC, restablecer la red y Windows Update, componentes de Windows. |
| **Deshacer** | Todo lo que ha cambiado Win Juicer, para devolverlo a como estaba. |
| **No hacemos** | Los «trucos» que circulan, y por qué no. |

Lo lento (leer el hardware, el diagnóstico, aplicar) va en segundo plano, y la
barra de estado dice qué está haciendo. La ventana no se deja cerrar mientras
está aplicando un cambio, para que nada quede a medias. Lo muy largo (winget, DISM, SFC) se abre
en su propia ventana para que veas su progreso.

La ventana recuerda su tamaño y dónde estaba, y cabe en pantallas pequeñas.
Atajos: **Esc** borra lo escrito en un buscador y vuelve de la página de un
juego a la galería, **Ctrl+F** lleva al buscador de la pestaña (juegos, ajustes
o programas) y **F5** vuelve a leer la pestaña.

Si prefieres la consola, o la ventana no puede abrirse, `WinJuicer.cmd -Consola`
abre el menú de texto, con lo mismo:

```
   1  Diagnóstico          hardware, overclock y BIOS: qué frena a este equipo
   2  Recomendado          lo que conviene a este equipo, según su hardware
   3  Perfiles             Seguro · Rendimiento · Extremo
   4  Ajustes uno a uno    estado, ganancia y coste; preferencias y componentes
   5  Debloat              las apps que vienen con Windows, una a una
   6  Programas de inicio  lo que arranca solo con Windows
   7  Juegos               GPU, prioridad y exclusiones de Defender
   8  Red y DNS            elegir servidor DNS
   9  Instalar programas   con winget: lanzadores, navegadores, herramientas
  10  Mantenimiento        limpieza, TRIM, reparar Windows, la red y Windows Update
  11  Deshacer             todo, o cambio a cambio
  12  Lo que no hacemos    los «trucos» que circulan, y por qué no
```

Una opción que no existe se dice («Opción no válida: x») y vuelve a pedir; si la
entrada se cierra (una tubería que acaba), los menús salen en vez de repetirse.

Debajo salen también **Antes y después**, **Ajuste fino**, **Protección contra
contenido adulto** y **Listo para jugar** (16), la misma tarjeta de Empezar. Si
Windows ha deshecho algo tuyo, el menú lo dice y **Deshacer** ofrece volver a
aplicarlo (V).

No se queda residente ni se conecta a internet salvo para lo que lo necesita
(winget, reinstalar una app de la Tienda, .NET 3.5). Funciona con Windows
PowerShell 5.1, la que ya trae Windows 10 y 11, y también con PowerShell 7.

### Desde la línea de órdenes

```powershell
.\WinJuicer.ps1 -Diagnostico
.\WinJuicer.ps1 -Informe C:\diagnostico.txt            # el diagnóstico, guardado en un archivo
.\WinJuicer.ps1 -Equipo                                 # hardware y qué conviene aquí, ajuste a ajuste
.\WinJuicer.ps1 -Recomendado -Simular                   # lo recomendado para este equipo, sin cambiar nada
.\WinJuicer.ps1 -Recomendado
.\WinJuicer.ps1 -Lista                                  # todos los ajustes y su estado
.\WinJuicer.ps1 -Revisar                               # qué ha deshecho Windows de lo que aplicaste (no cambia nada)
.\WinJuicer.ps1 -Revisar -Si                           # y volver a aplicarlo (los Extremo, con -AceptoRiesgos)
.\WinJuicer.ps1 -Estado                                # «Listo para jugar»: Modo juego, HAGS, Resizable BAR, energía, monitor
.\WinJuicer.ps1 -RestaurarDiario                       # diario dañado: restaura la copia anterior (diario.1.json)
.\WinJuicer.ps1 -Medir                                  # antes y después: comparado con la medida inicial
.\WinJuicer.ps1 -MedirJuego 60                          # FPS y frametimes de lo que juegues (empieza en 10 s)
.\WinJuicer.ps1 -MedirJuego 60 -Juego cs2.exe           # sólo ese juego
.\WinJuicer.ps1 -Juegos                                 # los juegos instalados y lo que tiene cada uno
.\WinJuicer.ps1 -OptimizarJuegos                        # frame pacer para tu monitor (y GPU dedicada) a todos
.\WinJuicer.ps1 -MantenerJuegos Activar                 # optimizar solos los juegos nuevos al iniciar sesión
.\WinJuicer.ps1 -Mantener                              # lo que hace esa tarea: optimizar los juegos nuevos y recalcular el frame pacer
.\WinJuicer.ps1 -LimitarFps cs2.exe,eldenring.exe       # frame pacer al ritmo recomendado, solo cada vez que los abras
.\WinJuicer.ps1 -LimitarFps cs2.exe -Fps 237            # o al tuyo
.\WinJuicer.ps1 -CalibrarJuego cs2.exe                  # lo mide con su ritmo y propone el que sostiene; lo aplica si dices que sí
.\WinJuicer.ps1 -CalibrarJuego cs2.exe -Si              # y aplica la propuesta sin preguntar
.\WinJuicer.ps1 -CalibrarJuego cs2.exe -Prioridad Latencia  # para competitivos: por encima de los Hz si da para ello
.\WinJuicer.ps1 -MotorPacer rtss                        # RivaTuner en vez del driver (admite décimas)
.\WinJuicer.ps1 -ModoPrudente Activar -Juego cs2.exe    # sólo el límite de FPS en ese juego (Desactivar para volver)
.\WinJuicer.ps1 -RestaurarPerfilesNvidia                # vuelve a la copia de los perfiles del driver (pregunta antes)
.\WinJuicer.ps1 -ApuntarAjuste -AjusteCpu 'Curve Optimizer -30' -AjusteGpu 'curva 900 mV, memoria +500' -HerramientaGpu Afterburner
.\WinJuicer.ps1 -OlvidarAjuste
.\WinJuicer.ps1 -ModoMonitor Estrobo                     # usas ELMB/DyAc sin VRR: el ritmo va exacto a los Hz
.\WinJuicer.ps1 -PantallaOled Si                         # tu monitor es OLED aunque su nombre no lo diga (No; Auto: por el nombre)
.\WinJuicer.ps1 -NuevaMedida                            # empezar a comparar desde ahora
.\WinJuicer.ps1 -Perfil Rendimiento
.\WinJuicer.ps1 -Aplicar juegos.ventana,pref.oscuro -Si # sin preguntar
.\WinJuicer.ps1 -Aplicar juegos.ventana -SinPuntoDeRestauracion -Si  # sin intentar crear el punto de restauración
.\WinJuicer.ps1 -QuitarApps Microsoft.BingNews,Clipchamp.Clipchamp
.\WinJuicer.ps1 -Dns Cloudflare
.\WinJuicer.ps1 -ProteccionAdultos Activar               # para siempre: estricta (o -NivelProteccion Equilibrado)
.\WinJuicer.ps1 -ProteccionAdultos Subir                 # de equilibrada a estricta, para siempre
.\WinJuicer.ps1 -BloquearWeb Reddit,ejemplo.com          # con la protección activa: bloqueadas para siempre
.\WinJuicer.ps1 -ProteccionAdultos Estado
.\WinJuicer.ps1 -ProteccionAdultos Comprobar            # ¿filtra de verdad en este PC? Y si no, por qué
.\WinJuicer.ps1 -Instalar Valve.Steam,Discord.Discord
.\WinJuicer.ps1 -Exportar C:\mi-config.json             # lo que Win Juicer cambió aquí
.\WinJuicer.ps1 -Importar C:\mi-config.json -Simular    # en otro PC: qué haría
.\WinJuicer.ps1 -Deshacer ui.menu
.\WinJuicer.ps1 -Deshacer ui.menu -Simular            # qué volvería, sin deshacer nada
.\WinJuicer.ps1 -DeshacerTodo
.\WinJuicer.ps1 -DeshacerTodo -Simular                  # lo que se deshará, sin tocar nada
.\WinJuicer.ps1 -Consola                                # el menú de texto en lugar de la ventana
```

`-Simular` enseña qué cambiaría sin cambiar nada con `-Recomendado`, `-Perfil`,
`-Aplicar`, `-QuitarApps`, `-Dns`, `-Importar`, `-Revisar`, `-Deshacer` y
`-DeshacerTodo`. Con cualquier otra acción que cambie algo o escriba un archivo
(`-LimitarFps`, `-OptimizarJuegos`, `-Instalar`, `-ProteccionAdultos`, `-Exportar`…)
se niega antes de hacer nada («-Simular no vale con -X: no puede enseñarse sin
hacerlo») y sale con 2.

Los ajustes del nivel Extremo y las apps marcadas «con cuidado» se confirman
siempre uno a uno; sin preguntas, sólo con `-AceptoRiesgos`. Código de salida:
0 si todo fue bien, 1 si algún ajuste falló, 2 si un argumento no es válido.
Estos códigos valen desde una consola de administrador: desde una que no lo es,
Win Juicer se vuelve a abrir con permisos elevados en otra ventana y la
original sale con 0 sin esperar el resultado.

## Recomendado para este equipo

Win Juicer lee de qué está hecho el equipo —procesador (y si es híbrido o un
Ryzen X3D), gráficas, RAM y su referencia comercial, disco de Windows, si es
portátil, si usa Modern Standby, impresoras, red, OneDrive, edición de Windows—
y decide para cada ajuste si es **recomendado**, **opcional** o **no
recomendado** aquí, y por qué. Algunos ejemplos de cómo cambia:

| Si tu equipo… | Win Juicer… |
|---|---|
| es un sobremesa | recomienda el plan de máximo rendimiento y quitar la limitación de energía |
| es un portátil | no recomienda el plan de máximo rendimiento (batería y calor); recomienda el «Modo de energía» (en Windows 10 y con Modern Standby; en Windows 11, opcional) para jugar enchufado |
| tiene Windows 10 | recomienda quitar «Noticias e intereses» de la barra de tareas (se refresca desde internet en segundo plano) |
| tiene un Ryzen 9 X3D de dos CCD (7900X3D, 7950X3D, 9900X3D, 9950X3D) | **no aplica** el plan sin aparcar núcleos: rompería el reparto de juegos al CCD con 3D V-Cache; y marca Game Bar como necesaria |
| tiene un Intel híbrido (núcleos P y E) | destaca quitar la limitación de energía, para que OBS o Discord no acaben en núcleos lentos |
| tiene una RTX 40 o posterior | recomienda la programación de GPU por hardware: la necesita la generación de fotogramas de DLSS |
| tiene una gráfica que no la admite | no la recomienda: Windows la ignoraría |
| tiene gráfica integrada o poca RAM | recomienda quitar transparencias, animaciones, Widgets y Edge en segundo plano |
| tiene Windows en un disco duro | recomienda apagar el indexado; con SSD, lo desaconseja |
| no tiene impresoras | recomienda desactivar la cola de impresión |
| tiene gráfica dedicada | recomienda que Windows Update no le cambie el driver |
| usa WSL o Docker, o es Windows Insider, o Home | desaconseja lo que los rompería o lo que Home ignora |

Ningún ajuste se queda con un «depende» genérico: cada uno lleva el motivo
concreto para tu equipo, también cuando la respuesta es «opcional».

«Para este equipo» nunca incluye preferencias ni componentes, y lo de nivel
Extremo sólo cuando el hardware lo pide (el indexado con disco duro), y aun así
se confirma.

## Revisión de hardware, overclock y BIOS

Parte del diagnóstico. Nada de esto se puede cambiar desde Windows, pero
Windows guarda las pruebas, y Win Juicer las lee:

- **XMP/EXPO, con certeza.** Lee la referencia de cada módulo (G.Skill,
  Corsair, Kingston FURY, Crucial, TeamGroup, ADATA, Patriot) y sabe a qué
  velocidad se vende el kit: «tu kit está certificado a 3600 y va a 2133». Avisa
  también de kits mezclados y de cuatro módulos DDR5.
- **Estabilidad del overclock** en los últimos 30 días: errores de hardware
  WHEA (procesador, memoria, PCIe), pantallazos azules con su código y la causa
  habitual (`WHEA_UNCORRECTABLE_ERROR`, `CLOCK_WATCHDOG_TIMEOUT`,
  `MEMORY_MANAGEMENT`…), apagados inesperados, cuelgues del driver de la
  gráfica, y las veces que el firmware frenó el procesador por temperatura o
  potencia.
- **La edad del driver de la gráfica**: avisa a los seis meses en una NVIDIA, una
  AMD dedicada o una Intel Arc (sacan drivers para los juegos nuevos cada pocas
  semanas) y al año en una integrada; para tarjetas que el fabricante ya sólo
  mantiene (NVIDIA GTX 10 y anteriores, AMD Polaris y Vega) no lo da por aviso, sólo
  como dato: su último driver puede ser el actual. Con la web de descarga del fabricante
  (nvidia.com/drivers, amd.com/support, intel.com/content/www/us/en/support/detect.html).
- **El plan de energía**: si limita el procesador por debajo del 100 % o tiene
  el turbo desactivado, cosa que algunas guías recomiendan y cuesta mucho.
- **BIOS y microcódigo**: Core de 13.ª/14.ª generación sin el microcódigo 0x12B
  que corrige su degradación; BIOS de AM5 anteriores a la corrección del voltaje
  SoC con EXPO; el fTPM de AMD que da tirones con BIOS antiguas; BIOS de hace
  años.
- **Ryzen X3D de dos CCD**: que estén el driver «3D V-Cache Performance
  Optimizer», Game Bar, el modo juego y el plan Equilibrado.
- **La gráfica**: límite de potencia bajado o subido (Afterburner), funcionando
  con menos líneas PCIe de las que tiene, Resizable BAR en NVIDIA RTX 30 o
  posterior, AMD RX 6000 o posterior e Intel Arc (en las demás no se puede, así que no se juzga)
  (en una Arc sin ReBAR, aviso grave), y qué ajustes del panel de NVIDIA o AMD
  sí merecen la pena.
- **Red**: sólo por wifi, o un cable que enlaza a 100 Mb/s.
- **Programas**: software de overclock (Afterburner, Ryzen Master, XTU,
  ThrottleStop), de RGB pesado (Armoury Crate, iCUE…) y antivirus de terceros
  preinstalados.
- **BitLocker** por software, como información: si lo quitas es decisión tuya.
- **Pantallas**: la frecuencia por debajo de la que admite el monitor, la
  resolución por debajo de la nativa (la lee del EDID del propio monitor) y, en
  un sobremesa con gráfica dedicada, un monitor conectado a la salida de la
  placa base.
- **Discos**: además del espacio libre, cuánta vida útil ha gastado cada SSD,
  si un NVMe pasa de 70 °C (y baja velocidad para protegerse) y lecturas que el
  disco no pudo recuperar.
- **Soporte de Windows**: hasta cuándo recibe parches de seguridad tu versión
  y edición (24H2 en Home y Pro dejó de recibirlos en octubre de 2026; Windows
  10, en octubre de 2025). Si una directiva `TargetReleaseVersion` te ata a una
  versión antigua (algunas herramientas de «debloat» la ponen) o tienes las
  versiones nuevas retrasadas, lo dice, y entonces no recomienda retrasarlas.
- **Combinaciones**: lo que sólo se ve mirando las piezas juntas.
  - La **RAM según el procesador**: en un Ryzen 5000 lo que rinde es 3600-3800
    en 1:1 con el Infinity Fabric, así que un kit de 4000 a 3600 está bien
    elegido y a 4000 pierde; en AM5, 6000-6400; en Zen 2 y anteriores, menos;
    las APU aguantan más. Ya no pide el XMP de un kit por encima de eso.
  - Qué **ajuste fino** admite tu Ryzen: Curve Optimizer en los X3D (los
    5000X3D y 7000X3D no se pueden subir de frecuencia), PBO completo en los
    9000X3D.
  - **Gráficas de 8 o 4 líneas PCIe** (RTX 4060/5060, RX 6600/7600, RX 6500
    XT, Arc B580…) en un procesador o una placa de PCIe 3.0 (APU de AM4,
    Ryzen 5500/5700, B450/A520, Intel de 10.ª o anterior, H510).
  - La **VRAM frente a la resolución** de tu monitor (8 GB a 1440p o 4K).
  - Una **APU sin gráfica dedicada**: la memoria que la BIOS le reserva (UMA
    Frame Buffer Size).
  - **Procesador y gráfica desequilibrados**: qué ajustes dan FPS y cuáles no
    según cuál de los dos manda.
  - **Portátil en modo híbrido**: la pantalla la dibuja la integrada; dónde
    se cambia a sólo la dedicada (MUX) según la marca.
  - Un **procesador híbrido de Intel en Windows 10**, sin Thread Director.

## Los tres perfiles

Cada nivel incluye los anteriores. Lo «a la carta» (preferencias, componentes,
OneDrive) no está en ningún perfil: sólo se aplica si lo eliges.

| Perfil | Qué cuesta |
|---|---|
| **Seguro** | Nada que nadie vaya a echar de menos. Incluye las reparaciones. |
| **Rendimiento** | Batería, estética o funciones que no todo el mundo usa: grabación de Game Bar, Widgets, animaciones, ubicación. |
| **Extremo** | Seguridad o funciones importantes. Cada ajuste se confirma por separado. |

## Qué hace

**Impacto** mide sólo rendimiento y peca de prudente: «bajo» quiere decir
pequeño, no cero. Si un ajuste está aquí con impacto bajo es porque no cuesta
nada, no porque vaya a hacer milagros.
Un ajuste que sólo hace que Windows *se sienta* más rápido sin dar FPS ni acelerar
nada de verdad (las animaciones) es «bajo», no «medio».

### Reparación — deshacer lo que otros «optimizadores» rompieron

Sólo actúan si encuentran el problema; si todo está bien, no escriben nada.

| Ajuste | Impacto |
|---|---|
| Reactivar SysMain (Superfetch) | Medio |
| Restaurar el archivo de paginación, si no hay ninguno | Alto |
| Activar TRIM en los SSD | Alto |
| Quitar `useplatformclock` (HPET forzado) del arranque | Medio |
| Desactivar `LargeSystemCache` | Medio |
| No vaciar la paginación en cada apagado | Medio |
| Reactivar el ajuste automático de TCP (descargas lentas) | Alto |
| Reactivar Windows Update | Bajo |
| Reactivar la precarga de programas (Prefetch) | Medio |
| Reactivar la compresión de memoria (no en Windows Server, donde viene apagada) | Medio |
| Reactivar BITS y Optimización de distribución (descargas de la Tienda, Game Pass y Windows Update) | Bajo |
| Reactivar los servicios de Xbox (inicio de sesión de Game Pass, partidas en la nube, mandos) | Bajo |
| Reactivar la caché de fuentes (FontCache) | Bajo |
| Reactivar la optimización semanal de unidades (TRIM del espacio libre en SSD) | Medio |
| Quitar `TdrLevel = 0`: que la gráfica se recupere de un cuelgue en vez de congelar el PC | Bajo |

### Energía

| Ajuste | Nivel | Impacto |
|---|---|---|
| Plan «Win Juicer»: Máximo rendimiento, sin aparcar núcleos ni ahorro en PCIe/USB/disco | Rendimiento | Medio |
| Modo de energía «Mejor rendimiento» (cualquier equipo con el plan Equilibrado) | Rendimiento | Medio |
| Sin limitación de energía para programas en segundo plano | Rendimiento | Bajo |
| Inicio rápido, con el archivo de hibernación reducido | Seguro | Medio |
| Hibernar tras 3 horas de suspensión con batería (sólo portátiles con hibernación; a la carta) | A la carta | Bajo |

El plan propio parte del «Máximo rendimiento» (Ultimate Performance) de
Windows y tiene un GUID fijo: ejecutar la herramienta dos veces no crea dos
planes, y deshacer lo borra. En la ventana son los botones «Añadir y activar» y
«Quitar». En un Ryzen X3D de dos CCD no se ofrece.

**En un portátil**, el plan también escribe valores para la batería (si no,
heredaría los de «Máximo rendimiento»: procesador clavado al 100 % y nada
durmiendo): procesador al 5 % como mínimo, aparcado de núcleos por defecto,
ahorro moderado en PCIe, suspensión selectiva de USB activada y disco que se
apaga a los 10 minutos. Enchufado sigue siendo el máximo. Deshacer borra el plan
entero, valores de batería incluidos.

**Modo de energía** es el control que Windows 10 pone en el icono de la batería
(y Windows 11 en Configuración > Energía). Sólo actúa con el plan **Equilibrado**:
con otro, el ajuste sale como no aplica («el control de modo de energía solo
actúa con el plan Equilibrado»). Windows guarda un modo **por fuente**, uno
enchufado y otro con batería: el ajuste cambia el de la fuente que uses al
aplicarlo, así que **aplícalo con el cargador conectado** para tener «Mejor
rendimiento» enchufado sin gastar batería. En un portátil con Windows 10 es el
ajuste de energía recomendado, en lugar del plan. Win Juicer no cuenta como
«deshecho por Windows» el modo de la batería cuando estás con batería.

### Juegos

| Ajuste | Nivel | Impacto |
|---|---|---|
| Modo juego | Seguro | Bajo |
| Programación de GPU acelerada por hardware (desde Windows 10 2004) | Seguro | Bajo |
| Optimizaciones para juegos en ventana (modelo flip en DX10/11) | Seguro | Medio |
| Reserva multimedia para segundo plano al 10 % | Seguro | Bajo |
| Frecuencia variable (VRR) también en juegos que no la piden | Rendimiento | Medio |
| Sin grabación en segundo plano de Xbox Game Bar | Rendimiento | Medio |
| Sin aceleración del ratón | Rendimiento | Bajo |
| Sin atajos de Teclas especiales (Mayús ×5) | Rendimiento | Bajo |

Y por juego, desde la pestaña **Juegos** (o el menú Juegos de la consola): GPU
de alto rendimiento y prioridad por encima de lo normal para un `.exe`, y exclusiones de Microsoft
Defender para las bibliotecas de Steam, Epic, GOG, Xbox, EA, Ubisoft, Battle.net y Riot
(Extremo; nunca una unidad entera ni una carpeta del sistema).

### Audio

Lo que de verdad cuenta en la latencia del sonido de un juego, por orden de
tamaño, y lo que Win Juicer hace con cada cosa:

- **Bluetooth: 100 a 300 ms.** El sonido por Bluetooth tarda entre 100 y 300 ms
  según el códec (más con el micrófono activo, en modo manos libres): cien veces
  más que cualquier ajuste de Windows. Para jugar, auriculares con cable, USB o
  con receptor propio de 2,4 GHz. El diagnóstico lo detecta (por el bus del
  adaptador, `BTHENUM` o `BTHLEDevice`) y lo marca con ⚠. Ningún programa puede
  arreglarlo.
- **Mejoras de audio.** Refuerzo de graves, sonido envolvente virtual,
  igualación de sonoridad y ecualizadores procesan el sonido antes de sacarlo, y
  algunos suman latencia y CPU. Si están activadas, el diagnóstico sugiere
  desactivarlas en Configuración > Sistema > Sonido > tu dispositivo > Mejoras de
  audio. Win Juicer no las toca: las gestiona el driver de cada fabricante y no
  hay una forma segura de apagarlas desde fuera. Si Windows no dice cómo están,
  no aparece nada.
- **48000 Hz.** Casi todos los juegos, Discord y los navegadores trabajan a
  48000 Hz; con otra frecuencia (44100 Hz, o 96000 Hz de «alta resolución»)
  Windows reconvierte el sonido de cada programa, con algo de CPU y de latencia.
  Sólo informa: si escuchas música en alta resolución, es una razón para dejarlo.
- **El período del motor de audio.** Windows mezcla el audio de todos los
  programas en períodos de 10 ms, y la partida entera, de que el juego emite el
  sonido a que sale por el altavoz, suma unos 20-30 ms. Desde Windows 10 un
  programa puede pedir un período más corto (128 muestras son 2,7 ms a 48 kHz) si
  el driver lo admite, y mientras alguno lo mantenga abierto el motor trabaja a
  ese período **para todos los programas** de esa salida, que siguen mezclados.
  El diagnóstico lo dice con las cifras de tu equipo («10 ms ahora; tu driver
  permite 2,7 ms», o «tu driver de audio no admite baja latencia»): el driver
  genérico de Windows («Dispositivo de audio de alta definición») suele admitirlo;
  muchos de fabricante informan un mínimo igual al período por defecto.

El ajuste **Audio de baja latencia** (`audio.latencia`) es esa petición, hecha
una vez por todos: un script pequeño que se queda abierto con un flujo
compartido y **silencioso** (no reproduce nada y no toma el dispositivo en
exclusiva) en la salida predeterminada, con el período mínimo del driver, y que
cambia de flujo si cambias de salida (auriculares que se enchufan, un driver que
se reinicia). Se ejecuta con tu usuario (las sesiones de audio son de cada
usuario; si Win Juicer corre como otra cuenta de administrador, ver «Un detalle
si tu cuenta no es de administrador»), sin ventana (la tarea usa `conhost --headless`, porque Windows Terminal ignora «oculta»; las tareas de versiones anteriores se corrigen solas), con prioridad baja y de uno en uno, como tarea programada
al iniciar sesión, y se pone en marcha en cuanto lo aplicas. Deshacer, o
«Deshacer todo», quita la tarea y el script y cierra el flujo: el audio vuelve a
10 ms.

- **Qué ahorra:** unos 5-7 ms de los 20-30 ms de latencia de salida. Se nota en
  juegos de ritmo o con sonido de pasos y disparos, no en los FPS. Medirlo en tu
  equipo es difícil sin instrumentos; la cifra viene de la diferencia entre los
  períodos, no de una medición.
- **Qué cuesta:** un proceso de PowerShell oculto siempre abierto (unas decenas
  de MB) y unos cientos de despertares de CPU por segundo: poca CPU, pero en un
  portátil, algo de batería. Es un ajuste **a la carta** (nivel 0, en ningún
  perfil) y no «Rendimiento» porque deja un proceso residente, depende de que el
  driver lo haga bien (con alguno, un período muy corto da chasquidos si el
  equipo va cargado) y sólo se nota en cierto tipo de juegos: lo elige quien lo
  quiere. Pruébalo con lo que juegas: si oyes chasquidos, deshaz.
- **Cuándo no se ofrece:** sin salida de audio activa, o si el driver informa un
  mínimo igual al período por defecto (no hay nada que ganar), con el motivo. Una
  vez aplicado, nunca se salta, para que siempre se pueda deshacer. En la ventana
  sale en la pestaña Ajustes (categoría Audio) y como botón «Aplicar» en el
  diagnóstico y en «Listo para jugar»; en consola,
  `-Aplicar audio.latencia`.

Lo que **no** hay, y por qué: ni **modo exclusivo** ni **ASIO** para juegos. El
modo exclusivo (y ASIO, que es lo mismo con otro driver) da la latencia más baja
que existe, pero sólo funciona si el *propio programa* lo pide, y los juegos no
lo hacen: hablan con el mezclador de Windows, y Discord, el navegador y el resto
de sonidos del sistema también. Un programa externo no puede «activarlo» en su
nombre, y quitar la casilla de exclusivo del dispositivo no gana nada. Es cosa
de estudios de música y de reproductores para audiófilos. Tampoco tocamos la
prioridad ni la afinidad de `audiodg.exe` ni desactivamos el HPET: no mueven el
período de mezcla, que es lo que manda (ver «Lo que no hace»).

### Tus juegos

La pestaña **Juegos** empieza por la lista de los juegos instalados, que Win
Juicer encuentra solo:
- Steam, por sus manifiestos.
- Epic, por los suyos (una instalación a medias no cuenta).
- GOG, por el registro.
- Xbox/Game Pass, por su `MicrosoftGame.config` (el ejecutable `Game`, no un
  ayudante de arranque).
- EA, Ubisoft, Battle.net, Riot, Rockstar, HoYoverse, Bethesda y Wargaming,
  por sus desinstaladores. Los lanzadores no cuentan como juegos, ni tampoco los
  anti-trampas (Vanguard, Easy Anti-Cheat, BattlEye) ni los agentes de
  actualización o de informe de errores.

Para cada uno busca el `.exe` que se ejecuta de verdad: el que declara la
tienda o, si no lo dice, el `*-Win64-Shipping.exe` de los juegos Unreal o el
ejecutable principal con su nombre, nunca un desinstalador, un lanzador o un
informe de errores. Lo recuerda, y con «Cambiar .exe…» eliges otro.

Un mismo juego sale **una sola vez**: si su tienda (Steam, Epic, GOG, Xbox) y el
registro de desinstalación (EA, Ubisoft, Battle.net, Riot…, o el lanzador del
propio juego) lo listan con la misma carpeta o una dentro de la otra, se junta
todo en una entrada, la de la tienda, con el mismo identificador de siempre y
con el `.exe` que habías elegido. El `.exe` que se elige es el del juego
(`*-Win64-Shipping.exe` en Unreal, hasta cinco niveles de carpetas), nunca un
lanzador (`MarvelRivals_Launcher.exe`).

Los muestra como una **galería**, agrupados por tienda (Steam, Epic, GOG,
Xbox…), con un buscador. Cada juego lleva su portada:
- **Steam**: la de la caché de su biblioteca, ya en tu PC. Steam guarda ahora
  cada juego en su carpeta con nombres que cambian, así que Win Juicer elige la
  vertical por su tamaño, leyendo sólo la cabecera de cada imagen. Si Steam no
  tiene vertical, se descarga la apaisada como recurso (`*.wide.jpg`), y en
  cuanto aparezca una vertical en tu PC la sustituye.
- **Xbox**: el logo que trae el propio juego en su carpeta.
- Si no está en tu PC, se descarga una vez de la tienda: Steam, Epic (la URL
  sale de la caché del catálogo de su lanzador) o GOG (su API pública). Sólo
  por HTTPS, sólo de sus servidores (también cada redirección, hasta tres), y
  sólo si lo que llega empieza como un JPEG
  o un PNG de tamaño normal. Lo que no existe (404) no se vuelve a buscar en
  una semana; si no hay conexión, o Epic todavía no tiene su catálogo o no lista
  el juego, no se apunta nada y se reintenta.
- Si no hay portada, el icono del propio `.exe` sobre un color.

Todo queda en `ProgramData\WinJuicer\portadas`. Los juegos ya optimizados
llevan su ritmo en la esquina, y los nuevos, «NUEVO».

**Optimizar todos**: a cada juego, el frame pacer al ritmo recomendado para tu
monitor y su modo, con la receta de baja latencia en NVIDIA, y la gráfica potente
si tienes dos. Se aplica solo cada vez que abras el juego.

**La página de cada juego** (pulsa su portada):
- **Optimizar este juego**, o **Quitar lo de Win Juicer**.
- **Frame pacer**: activado o no y, en palabras normales, **¿qué prefieres?**:
  *Fluidez* (el ritmo más estable, para la mayoría) o *Latencia mínima* (para
  competitivos, y lo dice en los que lo son: CS2, VALORANT, Fortnite, Apex…).
  **Ritmo**: *automático* (el recomendado o el calibrado para tu PC) o *elegido
  por ti*, que se respeta aunque cambies de monitor o de modo. **Calibrar**,
  con los pasos explicados antes de empezar y la duración a elegir (60, 90 o
  120 segundos): propone un ritmo (de tal a cual y por qué) y hasta que aceptas
  no cambia nada; después, **Verificar (45 s)**. Sin NVIDIA ni RivaTuner, un botón
  para instalar RivaTuner. **Modo prudente**: sólo el límite de FPS, sin tocar
  la sincronización vertical ni la cola de fotogramas, para un juego que se
  porta mal con lo demás.
- **¿Por qué este número?**: el cálculo del ritmo automático, a un clic bajo el
  ritmo (en la consola, debajo del ritmo en la información del juego). **Pides
  178 · efectivo ~171 (limita: Reflex con G-SYNC)**: lo que de verdad llega al
  juego, mirando lo que Win Juicer sabe leer: el perfil del propio NVIDIA para
  el juego, un límite en el perfil de NVIDIA o de RivaTuner (abierto), el
  global de RivaTuner o del panel, el límite propio del juego (Unreal), Reflex
  con G-SYNC (sólo con la V-Sync forzada, no en modo prudente) y el tope del
  VRR (que avisa, no recorta). Lo que no puede leer, no lo adivina.
- **Qué se ha puesto**, en palabras normales, después de aplicar: el límite y
  con qué motor, fotogramas pre-renderizados, V-Sync, lo que se deja porque
  NVIDIA ya lo fija, el modo prudente, lo que espera a que cierres el juego y
  cómo se deshace. En la ventana, en el mensaje y en la página; en la consola,
  tras `-LimitarFps` y en la información del juego.
- **Primera visita**: una explicación corta y descartable (qué es VRR, qué hace
  el frame pacer, por qué 171 y no 180 a 180 Hz); se recuerda en `interfaz.json`.
- **Más rendimiento**: la gráfica potente (con dos gráficas) y prioridad por
  encima de lo normal (no «alta»: con prioridad alta, un juego que ocupa un
  núcleo entero deja sin turno al sonido, al ratón y a sus propios hilos, y el
  equipo se puede congelar).
- **Medir**: tu última medida con su gráfica de frametimes, y un botón para
  medir este juego en concreto.
- **Calibración**: cuántos días hace y a cuántos FPS («calibrado hace 12 días a
  141 FPS»); pasados 30 días, o si ha cambiado el driver de la gráfica, la
  gráfica, la versión del juego o la de Windows desde que se calibró, una pista
  apagada: «ha cambiado el driver de la gráfica desde que se calibró: vuelve a
  calibrar» (o «puede haber cambiado (parche, ajustes)»). También en la lista
  de juegos y en el menú del frame pacer de la consola.
- **No es un juego: ocultar**, para una herramienta o un benchmark que Win Juicer
  ha tomado por juego. Lo saca de la galería y de «Optimizar todos» (y de la
  optimización automática); no borra nada ni toca lo que ya tuviera puesto. En
  la galería, «Mostrar ocultos (N)» los vuelve a enseñar y, en su página,
  «Volver a mostrar». Se recuerda en `juegos.json`. En la consola, **H** (ocultar),
  **M** (mostrar) y **O** (ver los ocultos) en la lista de juegos.
- **Dentro del juego**: los consejos de abajo.

Cada cambio en la página se aplica al momento y se deshace como todo lo demás.

**Que un juego no se congele ni se cierre por optimizarlo.**
- **Nunca con el juego abierto.** El driver le pasa los valores nuevos a un
  juego en marcha al momento, y cambiarle la sincronización vertical o la
  cola de fotogramas en plena partida puede congelarlo o cerrarlo. Si el juego
  está abierto (también al calibrar, que se hace jugando), el cambio espera:
  la galería lo marca «→ al cerrarlo» y se aplica solo en cuanto lo cierras.
  Si cierras Win Juicer antes, se aplica la próxima vez que lo abras o al
  iniciar sesión.
- **Lo que NVIDIA pone para cada juego, se queda.** Si el perfil del driver de
  un juego trae su propio valor de sincronización vertical o de cola de
  fotogramas, es porque ese juego lo necesita: Win Juicer no lo sobrescribe.
  Y si NVIDIA limita un juego a ciertos FPS porque por encima falla (física,
  temporizadores), el frame pacer no pasa de ahí.
- **Una receta más prudente.** Ya no pone «Preferir rendimiento máximo»: tenía
  la gráfica a tope incluso en menús y pantallas de carga, justo donde cede un
  overclock o un undervolt al límite o la refrigeración de un portátil. Lo que
  ya estaba aplicado de versiones anteriores se pone al día solo, una vez.
- **Si un juego empieza a fallar después de optimizarlo**, Win Juicer lo ve en
  el registro de Windows (un cierre con error o un cuelgue que Windows tuvo
  que cerrar) y, si antes no le pasaba, le quita sus cambios por si eran la
  causa, lo marca «⚠ protegido» y te lo explica. «Optimizar todos» y el
  mantenimiento automático lo dejan en paz; si lo vuelves a optimizar desde su
  página, es en modo prudente. Si ya fallaba antes, sólo te avisa: entonces no
  parece cosa de Win Juicer.
- **Con RivaTuner** el ritmo se marca a través de su enganche al juego (el
  mismo de su contador de FPS), y un antitrampas puede tomarlo por un truco.
  Win Juicer detecta el antitrampas de cada juego: Easy Anti-Cheat, BattlEye,
  EA Javelin (`EAAntiCheat*.exe`), nProtect GameGuard, XIGNCODE3, Tencent ACE
  (`AntiCheatExpert`, `ACE-*`), NetEase (`NeacSafe*`), mhyprot (HoYoverse),
  Ricochet (Call of Duty: su driver `atvi-randgrid*` o el nombre del `.exe`),
  Hyperion (Roblox), Riot Vanguard (su servicio `vgc` más un juego de Riot) y
  FACEIT (su servicio más CS2). Los de Ricochet por nombre, Tencent, NetEase,
  mhyprot y FACEIT por archivo se reconocen de memoria, sin una especificación:
  pueden fallar. Con un antitrampas y RivaTuner como único motor, **Optimizar,
  el mantenimiento automático y el ritmo a mano no ponen el frame pacer**:
  resultado «no aplica», «tiene antitrampas: RivaTuner se inyecta y podría dar
  problemas; usa el limitador del propio juego». El driver de NVIDIA, que no
  se inyecta, sigue como siempre. La misma nota sale en la página del juego y
  en la información del juego de la consola. Quien quiera RivaTuner igualmente
  puede pedirlo con `-LimitarFps`.
- Si sospechas de las «Optimizaciones para juegos en ventana» (de Ajustes),
  Windows deja quitarlas para un solo juego: Configuración > Sistema >
  Pantalla > Gráficos, el juego, Opciones.

**Dentro del juego**, en su página: lo que hay que poner en las opciones del
juego, que Win Juicer no puede cambiar desde fuera, para tu gráfica, tu
monitor y cómo lo usas:
- **Latencia:** NVIDIA Reflex («Activado + Boost» si tu medida dice que limita
  el procesador; también lo ofrece si la carpeta del juego trae sus archivos),
  AMD Anti-Lag 2 en los juegos que lo traen (CS2, Ghost of
  Tsushima) o Radeon Anti-Lag del panel en los demás.
- **Sincronización vertical y limitador del juego:** qué hacer según uses VRR,
  ELMB u otro estroboscopio, o frecuencia fija, para no sumar dos colas ni dos
  limitadores.
- **Si lo mediste**, qué bajar: lo que carga el procesador (distancia de
  visión, multitudes, físicas) o la gráfica (DLSS/FSR/XeSS, sombras, reflejos).
- **Juegos conocidos:** sabe cuáles de los más jugados tienen Reflex o Anti-Lag
  2 (CS2, VALORANT, Fortnite, Apex, Overwatch 2, Call of Duty, Rainbow Six
  Siege, Marvel Rivals, THE FINALS, PUBG, Cyberpunk 2077…) y lo particular de
  algunos, como que Elden Ring no pasa de 60 FPS. A los demás les da lo general.

**Optimizar automáticamente los juegos que instale** (casilla en la pestaña, o
`-MantenerJuegos Activar`): al iniciar sesión, sin abrir Win Juicer, optimiza
los juegos que hayas instalado desde la última vez y recalcula el frame pacer si
ha cambiado el monitor, sus Hz o cómo lo usas, y te avisa con una
notificación. Escribir los perfiles del driver de NVIDIA requiere permisos de
administrador. Por eso Win Juicer se copia a `Program Files`, donde sólo un
administrador puede cambiarlo, y la tarea ejecuta esa copia, que se actualiza
cada vez que abres una versión nueva. La tarea corre sin ventana (`conhost --headless`; la de versiones anteriores se corrige sola). Al desmarcarlo se quitan la tarea y la
copia.
Desde la consola, opción 0 del menú Juegos; desde la línea de órdenes,
`-Juegos` para listarlos y `-OptimizarJuegos` para optimizarlos todos.

### Medir FPS y frametimes

La única forma de saber si un ajuste da FPS es medir la misma escena antes y
después. Win Juicer lo hace con [PresentMon](https://github.com/GameTechDev/PresentMon),
la herramienta de Intel que usan las reviews y CapFrameX: se descarga de su
release de GitHub la primera vez y, cada vez antes de ejecutarlo, se comprueba
que lleva la firma de Intel.

Eliges tu escena más exigente y habitual (no un menú), sin Alt-Tab durante toda
la medida; pulsas «Medir», vuelves al juego en 10 segundos y juegas 30, 60 o 120
segundos. Al acabar dice:

- **Media, 1 % bajo y 0,1 % bajo** (los FPS del 1 % y el 0,1 % de fotogramas
  más lentos: lo que se siente como tirón), el frametime mediano y los
  **tirones por minuto**.
- **La latencia**: del inicio de cada fotograma a la pantalla y, cuando
  tocas el ratón o el teclado, de ahí a la pantalla (la mediana; PresentMon la
  mide por software, sin hardware aparte). Se compara con la medida anterior.
- **Qué limita**: si la gráfica va al máximo (para más FPS, calidad o
  DLSS/FSR/XeSS: ningún ajuste de Windows sube eso) o si **el procesador es el
  límite** y la gráfica espera (bajar gráficos no sirve; sí cerrar lo que gaste
  CPU, la RAM con XMP, el plan de energía y el frame pacer). Con un límite de
  FPS puesto la gráfica descansa parte de cada fotograma, y eso no es culpa del
  procesador: sólo se dice que limita el procesador o la gráfica si el más
  ocupado de los dos llena el 85 % del fotograma en el 95 % de los fotogramas;
  si no, «limitado por el ritmo, hay margen», y los consejos del juego no
  recomiendan «Boost» de Reflex ni bajar nada.
- **Qué gastaba CPU en segundo plano** mientras jugabas: navegador, lanzadores,
  Defender o Windows Update trabajando justo entonces. Se guarda con la medida.
- **Cómo llega la imagen a la pantalla**: directa (Independent Flip), compuesta
  por el escritorio (un fotograma más de latencia) o copiada con el modelo
  antiguo (lo arregla «Optimizaciones para juegos en ventana»).
- Si pasas de los Hz de tu pantalla, la sincronización vertical, la generación
  de fotogramas y, con NVIDIA, la temperatura, si la gráfica bajó de frecuencia
  (se pregunta cada segundo a `nvidia-smi` por la temperatura, el uso, el reloj,
  la memoria usada, la potencia y por qué se frenan los relojes; los campos que
  la tarjeta no da, «[N/A]», se ignoran) y la **VRAM llena** (95 % o más: las
  texturas pasan a la RAM y vienen los tirones). Con VRR en uso, avisa si el
  juego pasa por el escritorio (el VRR no actúa: pantalla completa exclusiva o
  G-SYNC para ventana, `NvVrrMode`) o si la V-Sync del propio juego está activa
  por debajo de los Hz (desactívala: la del driver ya hace ese papel).
- **El juego, entre varias cadenas de intercambio**: si un programa presenta
  fotogramas en más de una (un overlay, un vídeo de carga), se mide la que más
  fotogramas presentó, por proceso y cadena, no la suma.
- **Comparado con la medida anterior del mismo juego**: así ves si el último
  cambio dio FPS o sólo lo parecía. También el ritmo (qué parte de los
  fotogramas cae en su sitio y cuánto cambia uno del siguiente), la latencia
  y la cola delante de la gráfica: mide sin frame pacer, pónselo y vuelve a
  medir, y verás lo que gana. La comparación dice si cada medida se hizo **con o
  sin frame pacer** (y a cuántos FPS), porque comparar una con límite y otra
  sin él no compara tu PC.
- **Con qué se midió**, guardado en cada medida (las últimas 10 de cada juego):
  el límite que tenía, el motor, los Hz y el modo del monitor, la prioridad, el
  driver de la gráfica, la versión de PresentMon, si la gráfica se frenó o
  llegó a 85 °C, la VRAM y qué gastaba procesador. El ritmo recomendado sólo
  usa medidas de esta misma pantalla y modo, de menos de 60 días y sin la
  gráfica frenada.
- **La gráfica de frametimes** de toda la medida, con el objetivo del frame
  pacer como línea discontinua (en la consola, una línea de barras). Cada
  punto es el fotograma más lento de su tramo, para que ningún pico se pierda.
- **Si el juego tiene frame pacer, cómo de bien lo cumple** (ver abajo); si
  no, el ritmo que le conviene.

### Frame pacer

Un ritmo de fotogramas por juego, por frametime, pensado para frametimes
planos **sin sumar latencia**, que se aplica solo cada vez que abres el juego,
con Win Juicer cerrado:

- **Dónde**: con NVIDIA, en el limitador del propio driver («Velocidad máxima
  de fotogramas»), en el perfil de ese `.exe`, por NVAPI, la API oficial de
  NVIDIA (identificadores y estructuras de su `nvapi.h`). No se inyecta nada en
  el juego: los anti-trampas no tienen nada que objetar. Sin NVIDIA, en el
  perfil de ese juego de RivaTuner Statistics Server.
- **Según tu monitor y cómo lo usas.** El monitor no dice si tienes ELMB,
  DyAc o similar encendido, así que lo eliges una vez por monitor en «Cómo usas
  tu monitor» (o con `-ModoMonitor`): Automático, Frecuencia variable,
  Estroboscopio sin VRR, Estroboscopio con VRR (ELMB Sync, Aim Stabilizer
  Sync) o Frecuencia fija. «Recalcular los ritmos» los vuelve a poner con el
  modo nuevo. Si tu monitor es OLED y su nombre no lo delata (se reconocen
  muchas familias: PG32UCDM, AW3225QF, 27GR95QE, G80SD, MAG 271QPX…), dilo con
  `-PantallaOled Si|No|Auto` o en el menú del frame pacer de la consola («Tu
  monitor es OLED»): se guarda en `monitores.json` y manda sobre el nombre. En
  la ventana no hay interruptor todavía.
- **Cuánto**, como objetivo de frametime:
  - con frecuencia variable (con o sin estroboscopio), **Hz − Hz²/3600**, la
    cifra que usa NVIDIA Reflex (138 a 144 Hz, 157 a 165 Hz, 171 a 180 Hz, 224
    a 240 Hz): siempre dentro del rango VRR;
  - **con estroboscopio sin VRR** (por ejemplo ELMB a 180 Hz), **exactamente
    los Hz**, con la sincronización vertical forzada: cada destello necesita un
    fotograma nuevo, los cortes con estrobo se ven el doble, y como el juego no
    produce más fotogramas de los que la pantalla enseña no se forma cola. Nunca
    por debajo: repetiría fotogramas, y el estrobo los convierte en saltos. Si
    tus medidas dicen que un juego no llega a los Hz, te propone la frecuencia
    más alta de tu monitor que sí sostiene (para usar el estrobo ahí) o VRR
    para ese juego;
  - a frecuencia fija, los Hz;
  - y fuera del estroboscopio sin VRR, si mediste el juego y sus frametimes
    oscilan, **lo que sostiene el 90 % del tiempo**: un ritmo constante se nota
    más fluido que una media más alta con tirones.
- **El tope de Reflex.** En un juego con NVIDIA Reflex activado y G-SYNC con
  la sincronización vertical (la que Win Juicer fuerza en el driver con VRR),
  el propio juego se limita a Hz − Hz²/3600 (180 Hz a 171, 144 a 138, 240 a
  224) y manda el límite más bajo, así que un ritmo escrito a mano por encima
  de esa cifra y sin pasar de los Hz (por ejemplo 178 FPS a 180 Hz) no se
  alcanza nunca (Marvel Rivals con 178 a 180 Hz se queda en 171). Win Juicer
  lo aplica igualmente, y lo dice al aplicarlo (ventana y consola), en la
  página del juego y en los consejos de la consola. Para pasar de ahí habría
  que apagar Reflex en el juego, y se pierde latencia. Cómo sabe que un juego
  tiene Reflex, por tres caminos que se suman:
  - **La tabla** de juegos conocidos (CS2, VALORANT, Fortnite, Apex, Marvel
    Rivals…).
  - **Los archivos de su carpeta.** Mira, sólo por nombre y sin abrir nada
    (hasta tres niveles de la carpeta del juego, la del `.exe` y un máximo de
    archivos), si están `sl.reflex.dll` o `NvLowLatencyVk.dll` (Reflex),
    `nvngx_dlssg.dll` o `sl.dlss_g.dll` (DLSS Frame Generation, que fuerza
    Reflex) y `ffx_frameinterpolation*` (FSR 3). Lo recuerda por juego en
    `juegos.json` junto con la fecha de la carpeta, y lo vuelve a mirar si
    cambia (o pasados 30 días). Que estén los archivos dice que el juego
    **puede**; que lo tengas activado lo decides tú en sus opciones. Y que no
    estén no prueba nada: hay juegos que lo traen integrado.
  - **La medida.** Si mides un juego y su media cae justo en esa cifra (con
    margen de 1,5 FPS), con fotogramas parejos, la gráfica y el procesador
    sobrados y un ritmo mayor puesto, dice que lo limita Reflex o el modo de
    baja latencia «Ultra» con G-SYNC, no tu PC, y propone poner el ritmo en
    esa cifra. **Calibrar** no baja el ritmo en ese caso ni borra el que
    elegiste. Si en cambio la media queda por debajo del ritmo, pareja y con
    margen, pero no coincide con esa cifra, dice que algo externo limita y
    nombra los sospechosos habituales según tu gráfica: el límite del propio
    juego, Radeon Chill o Frame Rate Target Control en AMD, un límite del
    panel de NVIDIA o de RivaTuner, la V-Sync contra otra pantalla. Es lo que
    muestra la medida; Win Juicer no puede saber cuál de ellos es.
- **El límite del propio juego (Unreal).** En los juegos de Unreal Engine
  (`*-Win64-Shipping.exe`, como Marvel Rivals) lee, sin cambiar nada, su
  `GameUserSettings.ini` en `%LOCALAPPDATA%\<proyecto>\Saved\Config\Windows`
  (también `WindowsNoEditor` y `WinGDK`): `FrameRateLimit` y `bUseVSync`. Si el
  juego tiene su propio límite, la página del juego avisa («el juego tiene su
  propio límite a 144 FPS: con el de Win Juicer a 171 manda el menor») y
  sugiere dejarlo en ilimitado; si ya lo está, lo confirma. Si no encuentra el
  archivo, no dice nada.
- **La latencia**: un límite que el juego alcanza deja la gráfica por debajo
  del 100 %, así que no se forma cola de fotogramas, que es de donde sale la
  latencia. Con NVIDIA el perfil del juego recibe además la receta de baja
  latencia: fotogramas pre-renderizados a 1 («Modo de baja latencia:
  activado»; en juegos con **Reflex** manda Reflex, y el límite se aplica a
  través de él) y, con G-SYNC, la sincronización vertical forzada, que con el
  límite por debajo de los Hz no llega a actuar más que para tapar un corte en
  un pico (con estroboscopio sin VRR, para que cada destello tenga su
  fotograma). Lo que el perfil de NVIDIA de ese juego ya trae se respeta, y no
  se fuerza «Preferir rendimiento máximo». Win Juicer no lee ni cambia el modo
  «Ultra»: su identificador no es público. Lo que sí hace es detectar su tope
  al medir (ver «El tope de Reflex»), porque con G-SYNC y V-Sync se comporta
  como Reflex. La sincronización vertical del perfil siempre queda en uno de tres
  estados (forzada, desactivada o la del juego), así que cambiar de modo o de
  prioridad nunca deja puesta la del anterior. Un ritmo por encima de los Hz
  (escrito a mano o calibrado) nunca la fuerza: haría esperar cada fotograma
  al siguiente refresco.
- **Cómo de bien lo cumple.** Al medir un juego con frame pacer, la medida dice
  qué parte de los fotogramas cae en su sitio (a ±4 % del objetivo), cuánto
  cambia el frametime de un fotograma al siguiente, el error de animación de
  PresentMon (lo que el movimiento se desvía del tiempo real) y cuánto
  trabajaron de verdad el procesador y la gráfica en cada fotograma, que es el
  margen que queda. Si va por encima del objetivo, avisa de que el frame pacer
  no está actuando (RivaTuner cerrado, otro `.exe`).
- **La latencia, primero.** Un ritmo sólo baja la latencia si la gráfica no
  va al límite: si va, los fotogramas esperan en cola delante de ella, y esa
  cola es latencia pura. La medida lo ve directamente: cuánto espera cada
  fotograma entre que el procesador lo termina y la gráfica empieza con él
  (`GPULatency` − `CPUBusy` de PresentMon), y cuánto trabaja la gráfica de
  cada frametime. Si hay cola, lo dice, con la latencia de entrada a pantalla,
  y propone Reflex o Anti-Lag 2 si el juego los tiene (vacían la cola sin
  bajar el ritmo) o el «Modo de baja latencia: Ultra» del panel de NVIDIA
  para ese juego. Win Juicer no lo pone solo: ese ajuste no tiene un
  identificador público.
- **Calibrar** (un juego de la lista, o `-CalibrarJuego`): lo mide 60, 90 o 120
  segundos (a elegir) con su ritmo y **te propone** el que sostiene de verdad: de
  tal a cual, y por qué. No cambia nada hasta que aceptas (en la ventana, un
  cuadro con Aplicar o Descartar; en la consola, S/N; con `-CalibrarJuego`,
  sólo con `-Si`, y si no, pregunta, y sin respuesta no cambia nada). Antes de
  empezar dice cómo hacerlo: tu escena más exigente y habitual (no un menú), sin
  Alt-Tab, durante toda la medida. Si el 5 % más lento de
  los fotogramas no llega, lo baja a ese ritmo menos un 3 % de margen, sin salir
  nunca del rango VRR.
  Si lo sostiene pero con cola delante de la gráfica, lo baja **por latencia**
  hasta dejarle a la gráfica un 12 % de cada fotograma: menos fotogramas,
  pero cada uno llega antes a la pantalla. A frecuencia fija sin VRR ni
  sincronización vertical, cada fotograma de más es menos latencia, así que
  si sobra margen lo sube a un múltiplo de los Hz (2, 3 o 4 veces, para que
  los cortes de imagen se queden quietos).
  Si sobra trabajo de procesador y gráfica para bastante más, lo sube (hasta
  el máximo de tu monitor, dejando un 15 % de margen para los picos). Con
  estroboscopio sin VRR no baja nunca: te dice a qué frecuencia bajar el
  monitor. Lo recuerda por juego mientras el monitor, sus Hz y cómo lo usas
  sigan iguales; «Olvidar calibraciones» vuelve al ritmo recomendado. «Calibrado
  hace N días» sólo sale cuando esa calibración es la que manda ahora (mismo
  monitor y modo, y sin un ritmo tuyo por encima); si es de otro monitor o
  modo, lo dice así. Cada monitor (su firma: Hz, modo y monitor) tiene su
  calibración, y volver a uno encuentra la suya (se guardan las cuatro más
  recientes por juego; las de antes pasan solas a su firma). Con cada una se
  guarda con qué PC se hizo (la gráfica, su driver, la versión del juego, que sale
  del `buildid` de Steam o, si no, de la versión del `.exe`, y la de Windows): si
  alguna cambia, o pasan 30 días, sugiere repetirla.
- **Calibrar no se fía de cualquier medida.** No cambia nada, y dice «parece un
  menú o una pantalla de carga: repite en partida», si el procesador y la
  gráfica trabajaron menos del 25 % del fotograma y menos de 2 ms, o si la media
  fue menos del 55 % de la medida anterior de ese juego (que no estuviera por
  encima del límite). Un múltiplo de los Hz de la prioridad *Latencia* nunca pasa
  de 1,1 veces lo mejor que se vio de ese juego sin límite. Y no baja el ritmo,
  sino que dice «repite la medida: …», si la gráfica se frenó, llegó a 85 °C o
  algo (Defender, un navegador) gastaba el 12 % del procesador o más: bajarlo
  por eso sería bajarlo sin motivo.
- **Verificar (45 s).** Después de aplicar una propuesta, mide el juego otros 45
  segundos con el ritmo ya puesto (el juego tiene que haber arrancado con él: si
  estaba abierto, ciérralo y ábrelo; con la consola, la letra V; en la ventana, el
  botón que aparece junto a Calibrar). Si una bajada aún no llega, propone bajar
  otro poco, y se acepta igual. Una subida sólo se queda si la media coincide con
  el ritmo nuevo en un 3 % y se sostiene: si no, se vuelve al ritmo de antes (o
  baja a medias, si hasta ahí llegaba).
- **Un VRR que no llega a los Hz.** Si el monitor va a 165 Hz pero su rango VRR
  termina en 144, por encima de 144 el VRR se apaga: el ritmo se calcula con los
  144 (138 FPS) y lo dice («tu pantalla va a 165 Hz pero su VRR llega a 144»),
  también en la página del monitor. Calibrar nunca sube por encima.
- **Prioridad por juego: fluidez o latencia mínima.** Con fluidez (la de
  siempre), el ritmo más estable dentro de lo que el monitor enseña entero.
  Con **latencia**, pensada para competitivos: igual hasta que lo calibras;
  entonces, si el juego da para el doble de los Hz o más, sube a ese múltiplo
  (hasta 1000 FPS) con la sincronización vertical desactivada en su perfil:
  cada fotograma llega antes a la pantalla, a cambio de cortes de imagen, que
  a esos FPS apenas se ven. También con estroboscopio. Se elige en Juegos >
  Frame pacer junto al juego, en la consola (opción P) o con `-Prioridad`.
- **Generación de fotogramas** (DLSS, FSR): la medida la detecta y calibrar
  ya no sube ni baja el ritmo por la cola o el margen, que con fotogramas
  generados no se pueden leer bien; sólo lo baja si no se cumple. Con
  RivaTuner como motor avisa: se pelea con la generación y da tirones. Si la
  carpeta del juego trae sus archivos (ver «El tope de Reflex»), lo avisa
  **antes** de medir (en la confirmación de la ventana, en la página del juego
  y en la consola), y los consejos del juego recuerdan que el límite cuenta
  también los fotogramas generados: 171 FPS son unos 85 reales, y la
  generación de DLSS fuerza Reflex.
- **Un ritmo a menos de 3 FPS de los Hz.** Con VRR y la sincronización
  vertical forzada, un ritmo como 178 a 180 Hz puede hacer esperar fotogramas:
  al aplicarlo lo dice y propone el de Reflex (171) o menos.
- **Ritmos que se quedan atrás.** Si cambias de monitor, de modo o de Hz, o
  Win Juicer calcula el ritmo de otra manera, los juegos con ritmo automático
  pueden quedarse con el viejo (el mantenimiento al iniciar sesión sólo
  recalcula si está activado): el frame pacer lo avisa («tus juegos tienen 57
  FPS y para tus 180 Hz serían 171») y «Recalcular los ritmos» lo arregla. Los
  que elegiste tú no se tocan.
- **Límites que borra el driver.** Una instalación limpia del driver de
  NVIDIA, o reiniciar sus perfiles, se lleva los límites. Win Juicer los ve en
  el diario sin nada puesto: el mantenimiento al iniciar sesión los vuelve a
  poner (un juego abierto espera a que lo cierres) y lo apunta en el registro;
  en la ventana (tarjeta «Qué ha cambiado») y en `-Revisar` salen como «el
  driver borró el límite de N juegos», y `-Revisar -Si` o «Volver a
  aplicarlos» los restablece.
- **Otras pantallas, AMD y G-SYNC con módulo.** Con varias pantallas de
  distintos Hz o VRR, avisa de que el ritmo está calculado para la principal.
  Con AMD, recuerda que Radeon Chill y Frame Rate Target Control mandan si son
  más bajos. Con NVIDIA y un monitor que Windows ve como fijo (los G-SYNC con
  módulo no anuncian VRR), sugiere elegir «Frecuencia variable» en su modo.
- **Los Hz de verdad.** Windows dice 180 Hz, pero la pantalla suele ir a
  179,96. Win Juicer lee la fracción exacta (`QueryDisplayConfig`). Con
  estroboscopio y sincronización vertical eso importa: un ritmo de 180 es un
  pelo más rápido que la pantalla, la cola de la sincronización vertical se
  llena y vuelve un fotograma de latencia. RivaTuner admite décimas
  (`LimitDenominator`), así que con él el ritmo va 0,01 por debajo del
  refresco real («low-lag VSync»). El driver de NVIDIA sólo admite enteros, y
  Win Juicer te lo avisa.
- **Motor**: Automático (el driver si hay NVIDIA, si no RivaTuner), Driver de
  NVIDIA o RivaTuner (o `-MotorPacer`). Al cambiarlo, cada juego pasa al nuevo
  motor y se quita del anterior, y la receta de baja latencia sigue en su
  perfil de NVIDIA.
- **Un cambio en espera que falla** (el driver no contesta al cerrar el juego)
  no se pierde: vuelve a la lista con un contador de intentos, se avisa, y tras
  3 intentos se deja con un error visible y una línea en el registro.
- **Copia de los perfiles de NVIDIA.** Antes de la primera escritura de Win
  Juicer en el driver, copia `nvdrsdb*.bin` de `ProgramData\NVIDIA Corporation\Drs`
  a `respaldo-nvidia\<fecha>` (una sola vez; queda anotado en `frame-pacer.json`).
  Para volver: `-RestaurarPerfilesNvidia`, «N» en el menú del frame pacer de la
  consola o «Restaurar perfiles de NVIDIA…» en la ventana. Sustituye **todos** los
  ajustes de perfiles de NVIDIA por los de la copia, pide confirmación (con
  `-Si`, no) y hay que reiniciar el servicio del driver o, mejor, el equipo.
  `-Simular` lo rechaza.
- **Si NVAPI falla**, el mensaje sale en español («el driver de NVIDIA no
  responde: reinicia el equipo o actualízalo», «hace falta ejecutar Win
  Juicer como administrador…») con el código al final y el original en el
  registro. Un fallo de NVAPI se recuerda 30 segundos, no hasta cerrar Win
  Juicer.
- **Modo prudente por consola**: «T» en el menú del frame pacer o
  `-ModoPrudente Activar|Desactivar -Juego cs2.exe` (varios con comas). Ese menú
  también tiene «G» (ver un juego, y ofrece medirlo si nunca se midió).
- **Dos limitadores a la vez**: avisa si RivaTuner tiene un límite en su perfil
  Global o en el de un juego que ya tiene el ritmo del driver, si el panel de
  NVIDIA tiene un límite global, o si el motor es RivaTuner y no está abierto.
- **Lo que el panel de NVIDIA estropea**: si usas VRR y G-SYNC está
  desactivado, o activado sólo para pantalla completa (los juegos en ventana
  sin bordes se quedan sin él); y si la caché de sombreadores está
  desactivada o es muy pequeña, que da tirones que ningún ritmo arregla
  (identificadores del `NvApiDriverSettings.h` de NVIDIA).
- **RivaTuner abierto**: después de escribir un perfil, Win Juicer le pide que
  relea sus perfiles (`UpdateProfiles` de su propia `RTSSHooks64.dll`, desde
  RTSS 7.3.7), así el ritmo se aplica ya, sin reiniciarlo.
- Con RivaTuner, en su Setup: «Front edge sync» da la menor latencia y «Back
  edge sync» los frametimes más planos.
- Se deshace como todo lo demás, devolviendo el límite que tuviera el juego.
  Mide antes y después: la medida compara FPS, 1 % bajo y latencia.

### Ajuste fino: undervolt y overclock

Pestaña **Ajuste fino** (opción 14 de la consola). Para tu procesador y tu
gráfica concretos, dónde se hace, con qué valores empezar y cómo probarlo:

- **Procesador, en la BIOS.**
  - Ryzen 5000X3D (5700X3D, 5800X3D…): Curve Optimizer de -15 a -30, o un
    offset de -0,03 a -0,05 V.
  - 7000X3D: Curve Optimizer.
  - 9000X3D: Curve Optimizer más PBO y Boost Override.
  - Ryzen 5000/7000/9000: Curve Optimizer por núcleo y PBO.
  - Intel K de 12.ª a 14.ª: AC Load Line u offset, tras el microcódigo 0x12B
    en 13.ª y 14.ª.
  - Intel Core Ultra 200 K (Arrow Lake): guía prudente, con la BIOS al día y
    pasos pequeños de AC/DC Load Line u offset (10 mV) y prueba de estabilidad
    en cada uno.
  - La placa lo guarda y lo aplica en cada arranque, antes de Windows, sin
    ningún programa. Win Juicer no lo aplica desde Windows: las herramientas que
    lo hacen necesitan un driver de núcleo (WinRing0 y similares) que Microsoft
    Defender marca como vulnerable desde 2025 y que los anti-trampas vigilan.
- **Gráfica, en su herramienta**, con la receta de cada arquitectura:
  - RTX 50: frecuencia +200-300 y GDDR7.
  - RTX 40: curva a 0,95-1,00 V.
  - RTX 30: curva a 850-900 mV; la GDDR6X rinde menos, sin colgarse, si te
    pasas de memoria.
  - RTX 20/GTX 16, GTX 10, RX 9000/7000/6000/5000 e Intel Arc: cada una con
    su receta. Las tarjetas de estación de trabajo (RTX A, RTX Ada, RTX PRO,
    Quadro, Tesla) no tienen receta.
  - En un portátil (o una gráfica «Laptop», «Max-Q» o «Mobile») no se da la
    receta de sobremesa, sino una nota: sin tocar los límites de potencia,
    curva pequeña, que decida la temperatura y con la herramienta del fabricante.
  - Cómo hacer que se aplique en cada inicio: el perfil de Afterburner con
    «Aplicar overclock al iniciar el sistema», o AMD Software, que lo conserva
    salvo tras un cuelgue. La API pública de NVIDIA permite leer frecuencias y
    voltajes, no fijarlos, así que Win Juicer no escribe un overclock a ciegas.
- **Lo apuntas y lo vigila.** Escribes lo que aplicaste («Curve Optimizer
  -30», «curva 900 mV a 1900 MHz»). Win Juicer guarda también la versión de la
  BIOS y la velocidad de la RAM, y en cada inicio de sesión (una tarea como tu
  usuario, sin administrador) avisa con una notificación si:
  - una actualización de BIOS lo ha borrado;
  - la RAM ha vuelto a otra velocidad;
  - hay errores WHEA graves o corregidos (18, 19 y 47: los que delatan un
    undervolt o una RAM inestables; el resto de eventos de WHEA no cuentan) o
    cuelgues del driver de la gráfica desde entonces;
  - Afterburner ya no arranca con Windows.

Los valores son puntos de partida: cada chip es distinto. Pruébalos como dice
cada receta y mide FPS antes y después con «Antes y después» o Juegos > Medir.
Las cifras de ganancia de las recetas («un 5-10 %») salen de reseñas y foros,
no de tu equipo, y así se dice («según reseñas»): lo que cuenta es lo que midas.
El «-0,04 V» de los Ryzen 5000X3D es un punto de partida típico, no tu valor.

### El monitor

El diagnóstico lee el EDID de cada monitor: marca y modelo, **FreeSync** (y su
rango, y si tiene LFC), **VRR de HDMI 2.1** y **HDR** con su brillo. Con eso:

- Los pasos exactos para tu gráfica: G-SYNC en el panel de NVIDIA con la
  sincronización vertical como se debe y Reflex en los juegos; FreeSync en AMD
  Software; Adaptive Sync en Intel. Y que lo actives también en el menú del
  monitor, que a menudo viene apagado.
- Si su rango no tiene LFC, por debajo de qué FPS vuelven los tirones.
- La tecnología anti-desenfoque de tu marca (**ELMB** en ASUS, **DyAc** en
  BenQ, **VRB** en Acer, **Aim Stabilizer** en Gigabyte…) y si te serviría:
  sólo si el juego no baja nunca de los Hz, según tus medidas. Esto no viaja en
  el EDID: Win Juicer no puede saber si tu modelo la tiene ni si está
  encendida, por eso le dices cómo usas el monitor. Si usas el estroboscopio,
  los consejos cambian: el ritmo exacto a los Hz, que suele funcionar sólo a
  ciertas frecuencias, el overdrive que va con él, y qué juegos de tus medidas
  no llegan a los Hz y a qué frecuencia bajar para ellos.
- El overdrive en su nivel intermedio, y si su HDR merece la pena o es de
  entrada.
- G-Sync con módulo no se distingue desde Windows; en NVIDIA un monitor
  FreeSync funciona como «G-Sync Compatible» y los pasos son los mismos.

### Interfaz

| Ajuste | Nivel | Impacto |
|---|---|---|
| Sin apps promocionadas que Windows instala solo | Seguro | Bajo |
| Sin animaciones | Rendimiento | Bajo |
| Sin transparencias | Rendimiento | Bajo |
| Menú contextual clásico (sólo Windows 11; Windows 10 ya lo tiene) | Rendimiento | Bajo |
| Carpetas grandes al instante: sin detectar el tipo de cada carpeta | Rendimiento | Medio |
| Búsqueda de Inicio sin resultados de Bing ni «destacados de búsqueda» (en Windows 10 también `BingSearchEnabled` y `CortanaConsent`, que es lo que de verdad los quita) | Rendimiento | Bajo |
| Sin Widgets (en Windows 10, sin «Noticias e intereses»: se refresca desde internet y gasta CPU, RAM y batería) | Rendimiento | Bajo |

### Privacidad

Poco rendimiento aquí, y se dice. Lo que compran es menos cosas ejecutándose y
llamando a casa por su cuenta.

| Ajuste | Nivel | Impacto |
|---|---|---|
| Sin historial de actividad (en Windows 10 se pierde la Línea de tiempo de Win+Tab) | Seguro | Bajo |
| Sin identificador de publicidad ni encuestas | Seguro | Bajo |
| Telemetría al mínimo y sin sus tareas (adiós a los picos de CompatTelRunner) | Rendimiento | Bajo |
| Sin apps de fabricantes al conectar dispositivos | Rendimiento | Bajo |
| Ubicación desactivada | Rendimiento | Bajo |
| Copilot desactivado | Rendimiento | Bajo |

### Segundo plano, disco y red

| Ajuste | Nivel | Impacto |
|---|---|---|
| Servicio de telemetría (DiagTrack) deshabilitado | Seguro | Bajo |
| Apps de la Tienda sin segundo plano | Rendimiento | Bajo |
| Sin instantáneas de Recall (PC Copilot+) | Rendimiento | Bajo |
| Dos servicios que casi nadie usa, a manual | Rendimiento | Bajo |
| Cola de impresión desactivada, sólo si no hay impresoras | Rendimiento | Bajo |
| Edge sin procesos de fondo ni promociones | Rendimiento | Bajo |
| Sin nombres cortos 8.3 en NTFS | Rendimiento | Bajo |
| Sin fecha de último acceso en NTFS | Rendimiento | Bajo |
| Sin algoritmo de Nagle (sólo juegos TCP, como los MMO; sólo los adaptadores que hay al aplicarlo) | Rendimiento | Bajo |
| Sin indexado de búsqueda | Extremo | Bajo |
| Activar el Sensor de almacenamiento (sólo el interruptor general; a la carta) | A la carta | Bajo |

### Actualizaciones

Siguen activas: lo que cambia es qué llega por ellas y cuándo.

| Ajuste | Nivel |
|---|---|
| No compartir actualizaciones con otros equipos | Seguro |
| Windows Update no instala drivers (no te cambia el de la gráfica) | Rendimiento |
| Sin reinicios automáticos con la sesión abierta | Rendimiento |
| Versiones nuevas de Windows con un año de retraso (el «sólo seguridad» de WinUtil; no en Home) | Rendimiento |

### Seguridad: ganancias reales, costes reales

| Ajuste | Impacto |
|---|---|
| Desactivar la integridad de memoria (HVCI) | Alto |
| No arrancar el hipervisor (apaga VBS entero; rompe WSL 2, Hyper-V, Sandbox, Docker) | Medio |

Microsoft reconoce el coste de la integridad de memoria en juegos y propone
desactivarla a quien priorice jugar. Win Juicer lo ofrece, explica qué pierdes,
y no lo aplica sin que lo confirmes. Si BitLocker está activo, lo suspende
durante un reinicio antes de tocar la configuración de arranque, para que no te
pida la clave de recuperación.

### Preferencias y componentes (a la carta)

Interruptores en los dos sentidos: marcados, encendidos; desmarcados, lo
contrario, aunque ya estuviera así antes de Win Juicer.

- **Preferencias:** tema oscuro, mostrar extensiones de archivo, mostrar
  archivos ocultos, Bloq Num al iniciar, «Finalizar tarea» en la barra de tareas,
  barra de tareas a la izquierda, pantallazo azul con detalles (útil con
  overclock), mensajes detallados al arrancar, rutas largas, el Explorador
  abriendo en «Este equipo», Alt+Tab sólo con ventanas (sin las pestañas de
  Edge) y sin «Galería» en el panel del Explorador.
- **Componentes de Windows:** .NET Framework 3.5 y DirectPlay (juegos antiguos),
  WSL, Sandbox y Hyper-V.

### Debloat

Las apps que vienen con Windows, sólo las que estén instaladas, en tres grupos:

- **Seguras de quitar:** Noticias, El Tiempo, Bing, Obtener ayuda, Centro de
  opiniones, el lanzador de Microsoft 365, Solitaire, Clipchamp, Power Automate,
  Dev Home, Películas y TV, Mapas, Cortana y las promociones preinstaladas
  (Spotify, Netflix, Disney+, Prime Video, TikTok, Candy Crush).
- **Opcionales:** Copilot, Outlook nuevo, Teams, To Do, Enlace Móvil, Notas
  rápidas, Grabadora, Reloj, Cámara, Reproductor multimedia, WhatsApp, Skype…
- **Con cuidado:** la app Xbox, Xbox Game Bar y el proveedor de identidad de
  Xbox; en Windows 10, también **Paint 3D** (no es el Paint de siempre, que se
  queda, pero «Editar con Paint 3D» lo abre) y **Correo y Calendario**. Se
  confirman una a una.

En **Windows 10** salen además las apps que traía de serie: Consejos, Contactos,
Portal de realidad mixta, 3D Builder, Visor 3D, Print 3D y Planes móviles (todas
seguras), y Skype (opcional).

Si tu equipo usa una, sale marcada como **necesaria aquí**: Game Bar en un X3D
de dos CCD, la pila de Xbox si tienes juegos de Game Pass. La Tienda, la
Calculadora, Fotos o el Bloc de notas no se ofrecen.

Quitar una app la desinstala para todos los usuarios; **deshacer la reinstala
desde Microsoft Store** con winget. OneDrive también se puede desinstalar, salvo
que tus carpetas vivan dentro de él: entonces Win Juicer se niega y dice por
qué.

### Protección contra contenido adulto (opcional, y para siempre)

En **Empezar**, o en la consola (opción 15, o `-ProteccionAdultos Activar`).
Pensada también para quien quiere **dejar el porno**: bloquea ese contenido
**en todo el equipo**, en cualquier navegador, app o juego, y cierra los
atajos con los que se suele saltar un filtro en un mal momento. Nada filtra
dentro del PC, así que nada va más lento.

Dos niveles; se puede subir de equilibrada a estricta, nunca bajar:

| | Equilibrada | Estricta (la recomendada para una adicción) |
|---|---|---|
| Filtro DNS | [CleanBrowsing](https://cleanbrowsing.org/filters/), filtro de adultos | CleanBrowsing, filtro familiar: además proxies, VPN y webs con contenido mixto, como Reddit |
| El DNS puede ir a | cualquiera menos los públicos sin filtro (Google, Cloudflare, Quad9, OpenDNS, AdGuard, NextDNS…) | sólo al filtro |
| YouTube | modo restringido moderado | estricto |
| Ventanas privadas y de invitado | siguen | no hay (Chrome, Edge, Brave y Firefox) |
| Proxy en el navegador y VPN de Brave | siguen | no |
| Ventanas de Tor de Brave | no | no |

En los dos:

- **DNS filtrado** en cada adaptador físico, conectado o no, IPv4 e IPv6, con
  millones de dominios en listas que ellos mantienen al día. Una consulta
  cuesta lo mismo que con cualquier DNS público, y Windows guarda las
  respuestas. Si CleanBrowsing no responde, Cloudflare para familias
  (1.1.1.3) hasta que vuelva: nunca un DNS sin filtro, y nunca te quedas sin
  internet.
- **Cortafuegos de Windows**, para que cambiar el DNS no sirva de nada: seis
  reglas que bloquean el DNS que no debe salir (ver la tabla), el DNS cifrado
  por TLS y QUIC (puerto 853) y el DNS cifrado por HTTPS de los servidores
  públicos. Si el cortafuegos se apaga, vuelve a encenderse; si lo lleva otro
  programa (un antivirus con cortafuegos propio), se le deja: entonces sólo
  queda el filtro.
- **Navegadores**, por política: sin su DNS cifrado propio (preguntan al
  filtrado), con la búsqueda segura de Google y el modo restringido de
  YouTube, y en Edge la búsqueda segura estricta de Bing; en Firefox, su DNS
  cifrado apagado y bloqueado. Chrome, Edge y Brave se cierran del todo al
  cerrarlos, en vez de seguir en segundo plano con las respuestas de DNS de
  antes. En **Brave**, su buscador, Brave Search, funciona con su
  búsqueda segura obligatoria: el archivo hosts manda `search.brave.com` a las
  direcciones de `forcesafe.search.brave.com`, el mecanismo que Brave documenta
  para las redes, y la tarea las vuelve a consultar en cada revisión. Si nunca
  se han podido consultar (sin conexión al activarla), Brave Search queda
  bloqueado hasta que se pueda. Bloquearlo sin más no sirve: Brave no deja que
  una regla le cambie el buscador, y se quedaría sin poder buscar. Sus ventanas de Tor, que se saltan cualquier filtro,
  tampoco están. La búsqueda de Windows, en búsqueda segura
  estricta. Chrome y Edge dirán que los «administra tu organización»: son
  estas reglas.
- **Archivo hosts:** un bloque propio deja sin conexión la VPN que trae Opera,
  y las líneas que se añadan después enviando un nombre a una dirección de
  internet (la forma de saltarse un filtro DNS) se convierten en comentario.
  Lo que ya había antes de activarla, y lo que apunta al propio PC o a la red
  local, se queda como estaba.
- **Webs bloqueadas para siempre:** X, Reddit o Tumblr con un botón (con los
  nombres de sus imágenes y vídeos), u otra cualquiera escribiéndola. Se
  añaden al archivo hosts y no se pueden quitar.
- **Para siempre:** se activa tras dos confirmaciones (en la consola,
  escribiendo ACTIVAR) y después Win Juicer no la desactiva ni la baja de
  nivel: no hay botón ni orden para quitarla, «Deshacer todo» no la toca y el
  DNS queda fijo. Una tarea de Windows (como SYSTEM, desde la copia protegida
  de `Program Files`) la repone sola al arrancar, al iniciar sesión, al
  conectar una red, en cuanto cambia algo del cortafuegos y cada 15 minutos,
  con la prioridad más baja; si nada ha cambiado, no hace nada. Si otro
  programa deshace lo mismo una y otra vez, no se pelea con él: lo repone en
  la siguiente revisión. Con «mantener juegos» activado, su tarea también la
  revisa al iniciar sesión, y vuelve a crear la de la protección si alguien
  la borró.
- **Comprobar que funciona:** un botón (y `-ProteccionAdultos Comprobar`) que
  lo prueba de verdad: mira por qué adaptador sale tu conexión y si usa el
  DNS filtrado, pide a Windows una web para adultos para ver si la bloquea, y
  avisa de los navegadores abiertos desde antes de activarla. Si algo falla,
  dice qué y cómo arreglarlo; lo más habitual es una VPN que se lleva el
  tráfico o un navegador que seguía abierto en segundo plano.
- **En el móvil**, la misma idea: en Android, Ajustes, Red, DNS privado:
  `family-filter-dns.cleanbrowsing.org` (o `adult-filter-dns.cleanbrowsing.org`
  para la equilibrada).
- **Lo que no puede:** ver dentro de redes sociales o apps que sirven ese
  contenido desde sus propios dominios, ni frenar una VPN o Tor instalados
  como programa. En la equilibrada, Firefox bloquea las webs pero no obliga a
  la búsqueda segura. En la estricta, una VPN que traiga su propio DNS
  (también la del trabajo) no resuelve nombres, y alguna Wi-Fi de hotel cuya
  página de acceso sólo responde a su DNS puede no abrirse. Y quien
  administra el equipo siempre puede desmontarla a mano: ningún programa
  puede impedirlo, y Win Juicer no se esconde ni lucha contra Windows para
  intentarlo. Lo que hace es no ponerlo fácil, y volver a ponerla en cuanto
  se toca.

### DNS

Cloudflare (normal, contra malware, familiar), Google, Quad9, AdGuard (normal y
familiar), OpenDNS o automático. Se cambia en los adaptadores físicos
conectados y deshacer devuelve a cada uno lo que tenía. **No baja el ping**: el
DNS sólo se consulta al conectar. Sirve para privacidad, para filtrar malware o
anuncios, o porque el de tu operador falle.

### Instalar programas

Una lista corta, con winget: lanzadores (Steam, Epic, GOG, EA, Ubisoft,
Battle.net, Playnite…), navegadores, Discord y compañía, OBS, utilidades,
runtimes que piden los juegos (Visual C++, .NET) y las herramientas que menciona
la revisión de hardware (HWiNFO, CPU-Z, GPU-Z, CrystalDiskInfo, DDU,
NVCleanstall). Las sugeridas para tu equipo salen marcadas. Los identificadores
son los mismos que mantiene WinUtil.

### Listo para jugar

Una tarjeta en **Empezar** (y `-Estado`, o la opción 16 de la consola) que dice
de un vistazo, con ✓ o ⚠ y el motivo, si lo que importa para un juego está bien.
No cambia nada:

- **Modo juego** (en Windows 11 está activado mientras nadie lo apague).
- **Programación de GPU acelerada por hardware (HAGS)**: configurada y activa.
  Windows no la usa hasta reiniciar, así que si Win Juicer la puso después del
  último arranque (la última vez que la aplicó) lo dice («configurada, pero aún no activa»). Si el driver
  decide solo, o la gráfica no la admite, no aparece.
- **Optimizaciones para juegos en ventana** (el modelo de presentación moderno;
  con él la VRR también funciona en ventana o sin bordes). Si Windows no tiene
  escrita la opción, usa la suya por defecto y no se puede ver: no aparece.
- **Resizable BAR**, si se puede ver y la tarjeta lo admite (NVIDIA RTX 30 o
  posterior, AMD RX 6000 o posterior, Intel Arc): NVIDIA por `nvidia-smi`, el
  resto por los rangos de memoria que Windows dio a la tarjeta.
- **Plan de energía** (y si limita el procesador por debajo del 100 %), y si un
  portátil está **con batería** o enchufado. La fuente se lee una sola vez, con
  `GetSystemPowerStatus` de Windows (con WMI sólo si esa llamada falla).
- **Ahorro de batería** (en Windows 11 24H2, «Ahorro de energía»), sólo en
  portátiles y de sólo lectura: ⚠ «activo: Windows limita apps en segundo plano y
  brillo» si lo está ahora, o ℹ «se activa al 20 %» con la carga a la que el plan
  activo lo pone solo (`ESBATTTHRESHOLD`, lado batería; «no se activa solo» con 0).
  Win Juicer no lo enciende ni lo apaga.
- **El monitor**, a su frecuencia máxima o por debajo.

- **Grabación de Game Bar en segundo plano**, con los mismos valores del registro
  que cambia el ajuste «juegos.grabacion»: si está activa, ⚠ «graba en segundo
  plano: cuesta FPS» y apunta a ese ajuste. Sin forma de leerlo, no aparece.
- **Audio**, de la salida predeterminada: ⚠ si es **Bluetooth** (100-300 ms de
  retardo) o si las **mejoras de audio** están activadas (con la ruta de
  Configuración); ℹ si la frecuencia no es 48000 Hz, y una línea con el período
  del motor («10 ms ahora; tu driver permite 2,7 ms», «baja latencia en marcha» o
  «tu driver no la admite») que apunta al ajuste `audio.latencia`. Lo que Windows
  no dice, no aparece. Ver **Audio**, arriba.
- **Seguridad basada en virtualización (VBS / integridad de memoria)**, si está
  en marcha (la misma clase de Windows que lee el diagnóstico): sólo
  **informativa** (marca ℹ), nunca cuenta entre las cosas «por mirar»; quitarla es
  del nivel Extremo y decides tú.

Lo que no se puede leer **no aparece**: no se da por bueno ni por malo. Se calcula
en segundo plano al abrir la ventana, y de nuevo al aplicar algo.

Al abrir la ventana, Empezar se dibuja en cuanto se lee el hardware y el estado de los
ajustes; la comprobación de versiones, la protección, lo pendiente de los juegos, esta
tarjeta y el diagnóstico completo siguen después en segundo plano, sin bloquear los
botones (lo que pulses entre medias espera su turno y la ventana lo indica). Cada
programa externo que Win Juicer lanza (`powercfg`, `nvidia-smi`…) tiene un tiempo máximo,
salvo los que tardan de verdad (`dism`, `winget`). Si Win Juicer corre como otra
cuenta de administrador que la de la sesión, Empezar y la consola avisan: los
ajustes de usuario se aplicarían a esa otra cuenta.

### Qué ha cambiado: lo que Windows deshace

Una actualización de funciones de Windows, un instalador de drivers u otro
programa pueden devolver ajustes a su valor de fábrica sin avisar. Win Juicer
compara el diario con el estado real: los ajustes que aplicó y que **ya no
están en su sitio**. En Empezar sale una tarjeta, **sólo si hay algo**: «Windows
ha deshecho N cambios tuyos», con la lista y el botón **Volver a aplicarlos**.

- Vuelve a aplicarlos por el camino de siempre: los ajustes Extremo se confirman
  uno a uno, hay una pregunta antes y todo sigue en el diario, así que deshacer sigue devolviendo cada ajuste a como
  estaba antes de que Win Juicer lo tocara por primera vez.
- No cuenta lo que el motor se salta a propósito: lo que ya no aplica a este
  equipo, ni el perfil de un juego que está abierto (no se toca en marcha).
- En la consola: **Deshacer** lo lista y ofrece V para volver a aplicarlos, y
  `-Revisar` lo lista sin cambiar nada (código de salida 0); con `-Si` los aplica
  de nuevo (con `-AceptoRiesgos` para los Extremo, `-Simular` para ver qué haría).
- El mantenimiento de al iniciar sesión lo **apunta en el registro**
  (`registro.log`), pero nunca lo vuelve a aplicar por su cuenta.

### Programas de inicio

Lista lo que arranca con Windows —registro, carpetas de Inicio, tareas
programadas de terceros y servicios de terceros conocidos— y lo activa o
desactiva con el mismo interruptor que usa el Administrador de tareas. No borra
nada.

Los servicios se pasan a **manual**, no se deshabilitan: el programa todavía
puede arrancarlos cuando los necesita. Sólo aparecen los que Win Juicer conoce
(actualizadores y comprobación de licencia de Adobe, telemetría de Intel y HP,
la analítica de Killer, Nahimic, Armoury Crate, Razer, Corsair, TeamViewer,
AnyDesk, Bonjour…); el resto de servicios de terceros suelen ser drivers, audio
o antivirus, y una lista de «cosas que arrancan» sólo invitaría a apagarlos.

Reconoce los habituales y dice qué son: **prescindibles** (lanzadores de
juegos, Spotify, actualizadores de Adobe y Java, navegadores precargados…:
funcionan igual abriéndolos cuando hacen falta), **opcionales** (Discord,
OneDrive, el software de periféricos y RGB, Afterburner: según para qué los
uses) o **necesarios** (Seguridad de Windows, el panel de audio, el touchpad).
Los actualizadores de navegadores y antivirus no se tocan: son por donde llegan
los parches. El diagnóstico cuenta cuántos prescindibles arrancan.

**Cuánto retrasa cada uno el arranque**, medido por Windows y no estimado: junto
a cada entrada, «+12 s» son los segundos que Windows anotó en los últimos 30 días
(Diagnostics-Performance, eventos 101 de aplicaciones, 102 de drivers y 103 de
servicios; se queda con el más reciente de cada uno). Se enlaza por el nombre del
archivo (o del servicio). Windows sólo anota lo que va lento: **sin cifra** quiere
decir que no hay dato, no que valga cero. Los de 2 s o más salen resaltados, y
dentro de lo activado, los más lentos van primero.

### Antes y después

Justo antes de aplicar el primer cambio, Win Juicer toma una **medida
inicial**: tiempo del último arranque (el que cronometra Windows), programas,
tareas y servicios de inicio, procesos y servicios en marcha, memoria en uso y
espacio libre (y, en un portátil, la salud de la batería y la última
reanudación; ver **Portátiles**). «Medir antes y después» (o `-Medir`) mide otra vez y lo compara,
en verde lo que ha mejorado. El arranque sólo cambia después de reiniciar, y la
memoria y los procesos dependen de lo que tengas abierto: lo justo es medir las
dos veces recién reiniciado y con todo cerrado (si no, lo avisa). Windows no
dice si un arranque fue completo o con Inicio rápido (híbrido, mucho más corto
tras apagar), así que cada medida guarda si el Inicio rápido estaba activado; si
la inicial y la actual difieren, el arranque se compara con un aviso de que son
de distinto tipo (reiniciar siempre hace un arranque completo). «Nueva medida
inicial» empieza la comparación desde ahora.

### Portátiles

En un portátil (lo decide el chasis, no la batería: un sobremesa con SAI no lo
es) el diagnóstico añade una parte **Portátil**. Todo es lectura, está en
español y, si algo no se puede leer o no se entiende (Windows imprime sus
herramientas en el idioma del sistema), no sale nada en vez de una frase
equivocada:

- **Batería:** `powercfg /batteryreport` en XML, en un archivo temporal dentro
  de la carpeta de Win Juicer que se borra al leerlo. Con la capacidad de diseño,
  la de carga completa y los ciclos: «Tu batería conserva el 71 % de su
  capacidad original (412 ciclos)», Info; **Medio por debajo del 60 %**. Si
  casi siempre está enchufado (o no se sabe), recuerda que muchos fabricantes
  limitan la carga al 80 % desde su propio programa; Win Juicer **no escribe
  nunca** en esos ajustes. Ese porcentaje se guarda en cada medida de
  **Antes y después**, para ver cómo baja con los meses.
- **Reanudación:** el registro de rendimiento de Windows (evento 300) dice
  cuánto tardó la última salida de la suspensión: «La última reanudación tardó
  3,2 s», Info; **Medio a partir de 10 s**. Windows no documenta bien los campos
  de ese evento, así que se leen con cuidado y, si ninguno parece un tiempo
  creíble, no sale nada. También se compara en Antes y después.
- **Qué lo despierta y qué lo mantiene despierto:** `powercfg /lastwake`,
  `/waketimers` y `/requests`: lo último que despertó al portátil (un adaptador
  de red, un temporizador), las tareas con permiso para despertarlo y los
  procesos que impiden la suspensión. Es lo que explica un portátil que se
  descarga solo en la mochila.
- **Estados de suspensión:** `powercfg /a`, en llano: si usa la suspensión
  clásica (S3) o **Modern Standby** (S0), y si tiene hibernación e Inicio rápido.
- **Drivers:** el Wi-Fi con más de tres años (Bajo) y el del chipset si hasta el
  más reciente tiene más de tres. Los que vienen con Windows no cuentan: llevan
  la fecha del propio sistema. La gráfica ya tiene su aviso en Gráfica (sin
  driver, «el escritorio va a tirones»; la integrada desde un año).
- **8 GB de RAM:** consejos concretos (Edge «Pestañas en suspensión», Chrome
  «Ahorro de memoria», revisar la pestaña Arranque), y **Medio si la memoria
  comprometida pasa del 85 %**. La compresión de memoria se respeta: si estaba
  apagada, lo dice y cómo volver a encenderla; Win Juicer nunca la apaga.

Dos ajustes **a la carta**, deshacibles desde el diario:

- **Hibernar tras 3 horas de suspensión con batería** (sólo portátiles con la
  hibernación activada; si no, sale «no aplica» con el motivo). Cambia «Hibernar
  después de», lado batería, del plan activo: no gasta batería en la mochila y
  al abrirlo vuelves a donde estabas. No es lo mismo que apagar la hibernación,
  que no hacemos: ésta la necesita encendida.
- **Activar el Sensor de almacenamiento:** sólo el interruptor general (valor
  `01` de `StoragePolicy`); la frecuencia (`2048`, por defecto «cuando quede poco
  espacio») y lo demás se quedan como estén. El diagnóstico lo sugiere cuando el
  disco va justo de sitio y Windows lo tiene apagado. Si además usas la limpieza
  de Descargas del Sensor, éste decide por la fecha de último acceso: con «Sin
  fecha de último acceso en NTFS» aplicado, dejará de acertar.

**Fluidez del escritorio.** Cada medida de «Medir antes y después» incluye una
prueba pequeña y repetible: abre una ventana nueva del Explorador sobre una
carpeta temporal y mide hasta que aparece, y arranca el Bloc de notas hasta que
tiene ventana; cada una tres veces, y se guarda la mediana. Se ven unas
ventanas abrirse y cerrarse durante unos segundos. Se guarda con la **fuente de
energía** (enchufado o con batería), y sólo se compara con otra medida de la
misma: un portátil con batería rinde menos a propósito, y compararlo con uno
enchufado no es justo (lo dice). La medida que se hace sola antes del primer
cambio no incluye la prueba, para no abrir ventanas sin que lo pidas: para
tener el «antes» de fluidez, pulsa «Nueva medida inicial» antes de aplicar.

### Exportar e importar

Como en WinUtil: *Exportar* guarda en un JSON lo que Win Juicer ha cambiado en
este equipo —ajustes, preferencias, apps quitadas y DNS— y en otro PC
*Importar* lo aplica, con el mismo motor y el mismo diario, así que también se
deshace. Lo que sólo tiene sentido aquí (programas de inicio, ajustes de un
`.exe`) no se exporta, y lo que no aplique en el otro equipo se salta y lo dice.
Al importar desde la ventana, lo Extremo, las apps «con cuidado» y las que ese
equipo necesita se tratan como al aplicarlas o quitarlas a mano (ver arriba).

### Mantenimiento

Limpieza de temporales, informes de errores y descargas de Windows Update (antes
de limpiar calcula, sin borrar, cuánto libera cada carpeta y el total, y lo
enseña en la pregunta, en la ventana y en la consola; la carpeta de descargas de
Windows Update se deja si Windows espera un reinicio para terminar de instalar, y
lo dice);
TRIM o desfragmentado según la unidad (en un disco duro puede tardar horas, y
lo avisa antes); limpieza de componentes; DISM + SFC;
restablecer la red (Winsock y TCP/IP) y Windows Update (su caché se renombra, no
se borra, y sólo se guarda la última copia; vuelve a arrancar sólo los servicios
que estaban en marcha). Esto no se puede deshacer, así que sólo borra lo que Windows
regenera. **La caché de shaders y Prefetch no se tocan**: vaciarlas hace que la
siguiente partida tenga tirones.

## Lo que no hace, y por qué

No desactiva SysMain ni Prefetch, ni el archivo de paginación, ni la compresión de memoria,
ni Defender, ni Windows Update, ni las mitigaciones de Spectre. No desactiva los
servicios de Xbox, BITS ni Optimización de distribución, ni la detección de cuelgues
de la gráfica (`TdrLevel`). No «libera RAM».
No borra la caché de shaders. No fuerza el HPET. No toca las claves «Games» de
MMCSS ni `Win32PrioritySeparation`. No cambia la prioridad ni la afinidad de `audiodg.exe`, ni desactiva el HPET,
«para bajar la latencia del audio». No limpia el registro. No quita todas las
apps de la Tienda de golpe ni desactiva servicios en masa. No desinstala Edge a
la fuerza. No desactiva IPv6 ni Teredo. No cambia el DNS «para bajar el ping». No
desactiva Cortana por directiva en Windows 10 22H2: ya no está en la búsqueda y
no ahorra nada. No pone el procesador al 100 % mínimo con batería ni fuerza el
máximo rendimiento permanente en un portátil: con batería gasta la carga en
horas y calienta sin que el juego lo pida; el máximo es para enchufado.

Cada una de estas cosas tiene su explicación en **No hacemos**. Resumen: o no
hacen nada medible, o rompen algo, o las dos cosas. Varias, de hecho, las
**deshace** Win Juicer si otro programa las dejó puestas.

## Cómo deshace

Antes de cambiar nada, cada ajuste guarda en
`%ProgramData%\WinJuicer\diario.json` el valor exacto que había: si una clave no
existía, si un servicio estaba en automático retrasado, qué plan de energía
estaba activo, qué DNS tenía cada adaptador, qué apps estaban instaladas. El
diario se escribe *antes* de aplicar, para que ni un corte de luz a medias deje
el equipo sin vuelta atrás.

- **Deshacer** devuelve cada ajuste a como estaba antes de que Win Juicer lo
  tocara **por primera vez**, aunque lo hayas aplicado varias veces o hayas
  cambiado de DNS tres veces.
- Las claves que Win Juicer creó se borran al deshacer, salvo que otro programa
  haya escrito en ellas después.
- Cada ajuste se aplica entero o no se aplica: si una parte falla, lo ya hecho
  se revierte en el momento.
- Si Windows no conserva un cambio, se dice en lugar de darlo por bueno.
- La única excepción, a propósito, es la **protección contra contenido
  adulto**: no pasa por el diario, y ni «Deshacer» ni «Deshacer todo» la
  quitan (ver arriba). Deshacer un DNS que pusiste antes de activarla deja el
  filtrado como está.
- Antes de aplicar intenta crear un **punto de restauración**, y dice si
  Windows lo creó o no (sólo permite uno cada 24 horas).

- Cada vez que se guarda, el diario anterior (si se lee bien) queda como
  `diario.1.json`, escrito de golpe como el resto: un corte de luz no deja medio
  fichero. Si `diario.json` se daña, el error lo dice y se restaura con
  `-RestaurarDiario` (o desde **Deshacer** en la consola): aparta el dañado como
  `diario.dañado.json`, sin borrarlo, y pone la copia. La copia es un paso más
  antigua: si el diario actual se lee bien, pregunta antes (con `-Si`, no). La ventana,
al abrirla con el diario dañado, lo explica y ofrece restaurar la copia (si la hay);
si no, sigue con «Deshacer» vacío y no aplica cambios nuevos hasta recuperarlo.

La ventana y la consola usan el mismo diario: lo que hagas en una se deshace en
la otra. El registro de lo que se hizo, con fecha, queda en
`%ProgramData%\WinJuicer\registro.log`.

## Un detalle si tu cuenta no es de administrador

Si entras con una cuenta estándar y das permisos con la contraseña de *otra*
cuenta, los ajustes de usuario (ratón, animaciones, Game Bar…) se aplicarían a
la cuenta de administrador, no a la tuya. El diagnóstico lo detecta y avisa.

## Estructura

```
WinJuicer/
  WinJuicer.cmd           doble clic: arranca PowerShell sin que la política lo bloquee
  WinJuicer.ps1           pide administrador, parámetros de línea de órdenes
  WinJuicer.psm1          el módulo, que reúne src/
  src/Backend.ps1         único punto que toca registro, servicios, apps, DNS y características
  src/Engine.ps1          estado, aplicar, verificar, deshacer, interruptores y el diario
  src/Catalog.ps1         los ajustes, con su texto, y los mitos
  src/Native.ps1          SystemParametersInfo, modos de pantalla, Modern Standby, estado de la batería, núcleos híbridos
  src/Audio.ps1           la salida de audio (COM: IAudioClient3), su diagnóstico y el audio de baja latencia
  src/Hardware.ps1        de qué está hecho el equipo
  src/Advisor.ps1         qué conviene a este equipo, y por qué
  src/Audit.ps1           el diagnóstico
  src/Tuning.ps1          la revisión de hardware: BIOS, overclock, estabilidad
  src/Debloat.ps1         las apps que vienen con Windows, y OneDrive
  src/Network.ps1         DNS, restablecer la red y Windows Update
  src/Apps.ps1            instalar con winget
  src/Config.ps1          exportar e importar la configuración
  src/Measure.ps1         antes y después: medir y comparar
  src/Laptop.ps1          portátiles: batería, reanudación, qué despierta al equipo, suspensión, drivers
  src/Library.ps1         los juegos instalados y su .exe, y configurarlos en un paso
  src/Covers.ps1          portadas de la galería: caché de Steam, logos de Xbox, tiendas, icono
  src/Upkeep.ps1          mantener los juegos optimizados al iniciar sesión
  src/GameTips.ps1        qué poner dentro de cada juego según tu gráfica y tu monitor
  src/Frames.ps1          FPS y frametimes con PresentMon
  src/Monitor.ps1         el monitor: EDID, FreeSync, VRR, HDR y consejos
  src/Limiter.ps1         frame pacer por juego: ritmo, calibración, conflictos
  src/FineTune.ps1        undervolt de CPU y overclock de GPU: recetas, registro y vigilancia
  src/Version.ps1         aviso de versión nueva
  src/Startup.ps1         programas de inicio
  src/Games.ps1           bibliotecas de juegos y ajustes por ejecutable
  src/Maintenance.ps1     limpieza y mantenimiento
  src/Console.ps1         menús de texto y línea de órdenes
  src/Gui.ps1             la ventana
  build/                  el zip y el arrancador de «irm … | iex»
  tests/                  Pester
```

Todo lo que toca la máquina pasa por `Backend.ps1`, que tiene una versión en
memoria. Así el motor y **cada uno de los ajustes del catálogo** se prueban sin
Windows: se aplican sobre una máquina simulada —con los destrozos típicos de
otros optimizadores ya hechos— y se comprueba que deshacer la deja idéntica,
byte a byte. Lo mismo para quitar y reinstalar apps, cambiar el DNS de varios
adaptadores y los interruptores en los dos sentidos. Lo que interpreta el
hardware (referencias de RAM, microcódigo, nombres de procesadores y gráficas,
salida de powercfg y nvidia-smi, códigos de pantallazo) son funciones puras
probadas con las cadenas que dan equipos reales.

## Estado

Escrito y probado en Linux con PowerShell 7 y Pester: el motor, el diario, el
catálogo entero en ida y vuelta, los interruptores, el debloat, el DNS, el
consejero con perfiles de hardware de ejemplo, la revisión de hardware y la
línea de órdenes. El análisis estático comprueba que el código es válido en
Windows PowerShell 5.1.

En GitHub Actions corre además sobre Windows Server 2025 (compilación 26100, la
misma base que Windows 11 24H2), en 5.1 y en 7, contra el registro, los
servicios, powercfg y bcdedit de verdad: aplica los tres niveles completos en la
máquina del runner, lo deshace todo y comprueba que no queda rastro; hace la
revisión de hardware y estabilidad con los registros de eventos reales; lista
las apps y las características; y construye la ventana y dibuja cada pestaña.

Lo que una máquina virtual no tiene no se ha podido probar en ningún sitio: una
pantalla y una gráfica reales (nvidia-smi, Resizable BAR), batería y Modern
Standby, BitLocker, la hibernación, quitar y reinstalar apps de la Tienda de
verdad, winget, y la ventana vista por una persona. Es lo primero que conviene
mirar en un PC de verdad, empezando por la pestaña Equipo, que no cambia nada.

## Pruebas

```powershell
Invoke-Pester ./WinJuicer/tests
```

`Audio.Tests.ps1` cubre el diagnóstico y las líneas de «Listo para jugar» con salidas
simuladas (Bluetooth, mejoras activadas, 44,1 kHz, con y sin baja latencia, sin dato), el
ajuste «Audio de baja latencia» (cuándo se salta, que aplicar y deshacer anotan y quitan la
tarea) y que el C# declara cada interfaz COM entera y en orden. `Windows.Tests.ps1` comprueba
en Windows de verdad que ese C# compila (también en Windows PowerShell 5.1) y que el
diagnóstico responde sin tarjeta de sonido. `Features.Tests.ps1` cubre lo que Windows deshace, la copia del diario, los
tiempos de arranque, «Actualizar ahora» (sólo cómo se construye la orden: no
arranca nada), «Listo para jugar» y la edad de los drivers. `Mejoras.Tests.ps1`,
las confirmaciones con detalle, las opciones no válidas de los menús (y que sin
entrada salen), la grabación y VBS de «Listo para jugar», los juegos ocultos, la
edad de la calibración y la vista previa de la limpieza sobre carpetas temporales.
`Seguridad.Tests.ps1`, los antitrampas y RivaTuner, los cambios en espera que fallan, la
nota de Reflex en modo prudente, la copia y restauración de los perfiles de NVIDIA, los
mensajes de NVAPI, «pides y efectivo» y «qué se ha puesto». `Pacer.Tests.ps1`, el frame pacer: qué limita a un juego según la medida (Reflex, «Ultra»,
algo externo, el procesador, la gráfica o el propio ritmo), los archivos de Reflex y de
generación de fotogramas, el límite propio de Unreal, los ritmos atrasados, los límites
que borra el driver, la edad de la calibración, las propuestas de calibrar (la escena, la
gráfica frenada, la verificación), el historial por juego, una calibración por monitor con
su huella, la versión del juego y el rango del VRR, todo sobre la máquina en memoria y
carpetas temporales.

Las pruebas de `Windows.Tests.ps1` cambian de verdad la configuración del equipo,
nivel Extremo incluido, y luego la devuelven. Están pensadas para una máquina
desechable como la de CI, así que sólo se ejecutan en Windows, como
administrador **y** con `WINJUICER_PRUEBAS_REALES=1`. Sin esa variable se saltan.
