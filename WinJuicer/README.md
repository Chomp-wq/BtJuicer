# Win Juicer

Exprime Windows 11 para jugar y para cargar rápido, sin humo y con vuelta atrás.

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
se ejecute como administrador la próxima vez. La release la publica el CI
desde la rama principal, con todas las pruebas en verde.

**O sin internet**: descarga la carpeta `WinJuicer` (o el `WinJuicer.zip` de la
release) y haz doble clic en **`WinJuicer.cmd`**. Pide permisos de
administrador y abre la ventana. Una copia descargada de la release sabe qué
versión es: al abrirse mira si hay otra más nueva (lee la versión del
arrancador publicado, 3 KB, nada más) y, si la hay, lo dice arriba con un botón
para copiar la orden de una línea.

| Pestaña | Qué tiene |
|---|---|
| **Equipo** | El hardware detectado y el diagnóstico completo, BIOS y overclock incluidos. Botones «Aplicar lo recomendado para este equipo», «Guardar informe» (un .txt en el escritorio, para guardarlo o pedir ayuda en un foro) y «Medir antes y después». |
| **Ajustes** | Todos los ajustes con casillas, agrupados. Selección: *Para este equipo* · *Seguro* · *Rendimiento* · *Extremo*. A la derecha, las preferencias (tema oscuro, extensiones…), el plan de máximo rendimiento y el DNS. *Exportar…* e *Importar…* llevan tu configuración a otro PC. |
| **Debloat** | Las apps que vienen con Windows y siguen instaladas, una a una, con lo que es cada una. |
| **Instalar** | Programas habituales con winget: lanzadores de juegos, navegadores, herramientas de hardware. |
| **Inicio** | Lo que arranca solo con Windows, con el mismo interruptor del Administrador de tareas, y qué es cada cosa: prescindible, opcional o necesaria. Botón para desactivar de golpe los prescindibles. |
| **Juegos** | Medir FPS y frametimes (media, 1 % y 0,1 % bajos, tirones, qué limita), limitador de FPS por juego, GPU de alto rendimiento y prioridad alta para el `.exe` de un juego, y exclusiones de Defender para las bibliotecas de Steam, Epic, GOG y Xbox que encuentra. |
| **Mantenimiento** | Limpieza, TRIM, DISM y SFC, restablecer la red y Windows Update, componentes de Windows. |
| **Deshacer** | Todo lo que ha cambiado Win Juicer, para devolverlo a como estaba. |
| **No hacemos** | Los «trucos» que circulan, y por qué no. |

Lo lento (leer el hardware, el diagnóstico, aplicar) va en segundo plano, y la
barra de estado dice qué está haciendo. La ventana no se deja cerrar mientras
está aplicando un cambio, para que nada quede a medias. Lo muy largo (winget, DISM, SFC) se abre
en su propia ventana para que veas su progreso.

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

No se queda residente ni se conecta a internet salvo para lo que lo necesita
(winget, reinstalar una app de la Tienda, .NET 3.5). Funciona con Windows
PowerShell 5.1, la que ya trae Windows 11, y también con PowerShell 7.

### Desde la línea de órdenes

```powershell
.\WinJuicer.ps1 -Diagnostico
.\WinJuicer.ps1 -Informe C:\diagnostico.txt            # el diagnóstico, guardado en un archivo
.\WinJuicer.ps1 -Equipo                                 # hardware y qué conviene aquí, ajuste a ajuste
.\WinJuicer.ps1 -Recomendado -Simular                   # lo recomendado para este equipo, sin cambiar nada
.\WinJuicer.ps1 -Recomendado
.\WinJuicer.ps1 -Lista                                  # todos los ajustes y su estado
.\WinJuicer.ps1 -Medir                                  # antes y después: comparado con la medida inicial
.\WinJuicer.ps1 -MedirJuego 60                          # FPS y frametimes de lo que juegues (empieza en 10 s)
.\WinJuicer.ps1 -MedirJuego 60 -Juego cs2.exe           # sólo ese juego
.\WinJuicer.ps1 -LimitarFps cs2.exe,eldenring.exe       # límite recomendado, aplicado solo cada vez que los abras
.\WinJuicer.ps1 -LimitarFps cs2.exe -Fps 237            # o el tuyo
.\WinJuicer.ps1 -ModoMonitor Estrobo                     # usas ELMB/DyAc sin VRR: el límite va exacto a los Hz
.\WinJuicer.ps1 -NuevaMedida                            # empezar a comparar desde ahora
.\WinJuicer.ps1 -Perfil Rendimiento
.\WinJuicer.ps1 -Aplicar juegos.ventana,pref.oscuro -Si # sin preguntar
.\WinJuicer.ps1 -QuitarApps Microsoft.BingNews,Clipchamp.Clipchamp
.\WinJuicer.ps1 -Dns Cloudflare
.\WinJuicer.ps1 -Instalar Valve.Steam,Discord.Discord
.\WinJuicer.ps1 -Exportar C:\mi-config.json             # lo que Win Juicer cambió aquí
.\WinJuicer.ps1 -Importar C:\mi-config.json -Simular    # en otro PC: qué haría
.\WinJuicer.ps1 -Deshacer ui.menu
.\WinJuicer.ps1 -DeshacerTodo
```

Los ajustes del nivel Extremo y las apps marcadas «con cuidado» se confirman
siempre uno a uno; sin preguntas, sólo con `-AceptoRiesgos`. Código de salida:
0 si todo fue bien, 1 si algún ajuste falló, 2 si un argumento no es válido.

## Recomendado para este equipo

Win Juicer lee de qué está hecho el equipo —procesador (y si es híbrido o un
Ryzen X3D), gráficas, RAM y su referencia comercial, disco de Windows, si es
portátil, si usa Modern Standby, impresoras, red, OneDrive, edición de Windows—
y decide para cada ajuste si es **recomendado**, **opcional** o **no
recomendado** aquí, y por qué. Algunos ejemplos de cómo cambia:

| Si tu equipo… | Win Juicer… |
|---|---|
| es un sobremesa | recomienda el plan de máximo rendimiento y quitar la limitación de energía |
| es un portátil | no lo recomienda (batería y calor); con Modern Standby, usa el «Modo de energía» |
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
- **El plan de energía**: si limita el procesador por debajo del 100 % o tiene
  el turbo desactivado, cosa que algunas guías recomiendan y cuesta mucho.
- **BIOS y microcódigo**: Core de 13.ª/14.ª generación sin el microcódigo 0x12B
  que corrige su degradación; BIOS de AM5 anteriores a la corrección del voltaje
  SoC con EXPO; el fTPM de AMD que da tirones con BIOS antiguas; BIOS de hace
  años.
- **Ryzen X3D de dos CCD**: que estén el driver «3D V-Cache Performance
  Optimizer», Game Bar, el modo juego y el plan Equilibrado.
- **La gráfica**: límite de potencia bajado o subido (Afterburner), funcionando
  con menos líneas PCIe de las que tiene, Resizable BAR en NVIDIA, AMD e Intel
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

### Energía

| Ajuste | Nivel | Impacto |
|---|---|---|
| Plan «Win Juicer»: Máximo rendimiento, sin aparcar núcleos ni ahorro en PCIe/USB/disco | Rendimiento | Medio |
| Modo de energía «Mejor rendimiento» (portátiles con Modern Standby) | Rendimiento | Medio |
| Sin limitación de energía para programas en segundo plano | Rendimiento | Bajo |
| Inicio rápido, con el archivo de hibernación reducido | Seguro | Medio |

El plan propio parte del «Máximo rendimiento» (Ultimate Performance) de
Windows y tiene un GUID fijo: ejecutar la herramienta dos veces no crea dos
planes, y deshacer lo borra. En la ventana son los botones «Añadir y activar» y
«Quitar». En un Ryzen X3D de dos CCD no se ofrece.

### Juegos

| Ajuste | Nivel | Impacto |
|---|---|---|
| Modo juego | Seguro | Bajo |
| Programación de GPU acelerada por hardware | Seguro | Bajo |
| Optimizaciones para juegos en ventana (modelo flip en DX10/11) | Seguro | Medio |
| Reserva multimedia para segundo plano al 10 % | Seguro | Bajo |
| Frecuencia variable (VRR) también en juegos que no la piden | Rendimiento | Medio |
| Sin grabación en segundo plano de Xbox Game Bar | Rendimiento | Medio |
| Sin aceleración del ratón | Rendimiento | Bajo |
| Sin atajos de Teclas especiales (Mayús ×5) | Rendimiento | Bajo |

Y por juego, desde la pestaña **Juegos** (o el menú Juegos de la consola): GPU
de alto rendimiento y prioridad alta para un `.exe`, y exclusiones de Microsoft
Defender para las bibliotecas de Steam, Epic, GOG y Xbox (Extremo).

### Medir FPS y frametimes

La única forma de saber si un ajuste da FPS es medir la misma escena antes y
después. Win Juicer lo hace con [PresentMon](https://github.com/GameTechDev/PresentMon),
la herramienta de Intel que usan las reviews y CapFrameX: se descarga de su
release de GitHub la primera vez y, cada vez antes de ejecutarlo, se comprueba
que lleva la firma de Intel.

Pulsas «Medir», vuelves al juego en 10 segundos y juegas 30, 60 o 120
segundos. Al acabar dice:

- **Media, 1 % bajo y 0,1 % bajo** (los FPS del 1 % y el 0,1 % de fotogramas
  más lentos: lo que se siente como tirón), el frametime mediano y los
  **tirones por minuto**.
- **Qué limita**: si la gráfica va al máximo (para más FPS, calidad o
  DLSS/FSR/XeSS: ningún ajuste de Windows sube eso) o si **el procesador es el
  límite** y la gráfica espera (bajar gráficos no sirve; sí cerrar lo que gaste
  CPU, la RAM con XMP, el plan de energía y un límite de FPS).
- **Qué gastaba CPU en segundo plano** mientras jugabas: navegador, lanzadores,
  Defender o Windows Update trabajando justo entonces.
- **Cómo llega la imagen a la pantalla**: directa (Independent Flip), compuesta
  por el escritorio (un fotograma más de latencia) o copiada con el modelo
  antiguo (lo arregla «Optimizaciones para juegos en ventana»).
- Si pasas de los Hz de tu pantalla, la sincronización vertical, la generación
  de fotogramas y, con NVIDIA, la temperatura y si la gráfica bajó de frecuencia.
- **Comparado con la medida anterior del mismo juego**: así ves si el último
  cambio dio FPS o sólo lo parecía.
- **El límite de FPS que le conviene a ese juego**, para el limitador.

### Limitador de FPS

Un límite por juego, pensado para frametimes planos **sin sumar latencia**, que
se aplica solo cada vez que abres el juego, con Win Juicer cerrado:

- **Dónde**: con NVIDIA, en el limitador del propio driver («Velocidad máxima
  de fotogramas»), en el perfil de ese `.exe`, por NVAPI, la API oficial de
  NVIDIA (identificadores y estructuras de su `nvapi.h`). No se inyecta nada en
  el juego: los anti-trampas no tienen nada que objetar. Sin NVIDIA, en el
  perfil de ese juego de RivaTuner Statistics Server.
- **Según tu monitor y cómo lo usas.** El monitor no dice si tienes ELMB,
  DyAc o similar encendido, así que lo eliges una vez por monitor en «Cómo usas
  tu monitor» (o con `-ModoMonitor`): Automático, Frecuencia variable,
  Estroboscopio sin VRR, Estroboscopio con VRR (ELMB Sync, Aim Stabilizer
  Sync) o Frecuencia fija. «Recalcular los límites» los vuelve a poner con el
  modo nuevo.
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
- **La latencia**: un límite que el juego alcanza deja la gráfica por debajo
  del 100 %, así que no se forma cola de fotogramas, que es de donde sale la
  latencia. Con NVIDIA el perfil del juego recibe además la receta de baja
  latencia: fotogramas pre-renderizados a 1 («Modo de baja latencia:
  activado»; en juegos con **Reflex** manda Reflex, y el límite se aplica a
  través de él) y, con G-SYNC, la sincronización vertical forzada, que con el
  límite por debajo de los Hz no llega a actuar más que para tapar un corte en
  un pico (con estroboscopio sin VRR, para que cada destello tenga su
  fotograma). El modo «Ultra» no tiene un identificador público y no se toca.
- Con RivaTuner, en su Setup: «Front edge sync» da la menor latencia y «Back
  edge sync» los frametimes más planos.
- Se deshace como todo lo demás, devolviendo el límite que tuviera el juego.
  Mide antes y después: la medida compara FPS, 1 % bajo y latencia.

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
  los consejos cambian: el límite exacto a los Hz, que suele funcionar sólo a
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
| Sin animaciones | Rendimiento | Medio |
| Sin transparencias | Rendimiento | Bajo |
| Menú contextual clásico | Rendimiento | Bajo |
| Búsqueda de Inicio sin resultados de Bing | Rendimiento | Medio |
| Sin Widgets | Rendimiento | Bajo |

### Privacidad

Poco rendimiento aquí, y se dice. Lo que compran es menos cosas ejecutándose y
llamando a casa por su cuenta.

| Ajuste | Nivel | Impacto |
|---|---|---|
| Sin historial de actividad | Seguro | Bajo |
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
| Sin algoritmo de Nagle (sólo juegos TCP, como los MMO) | Rendimiento | Bajo |
| Sin indexado de búsqueda | Extremo | Bajo |

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
  overclock), mensajes detallados al arrancar, rutas largas.
- **Componentes de Windows:** .NET Framework 3.5 y DirectPlay (juegos antiguos),
  WSL, Sandbox y Hyper-V.

### Debloat

Las apps que vienen con Windows, sólo las que estén instaladas, en tres grupos:

- **Seguras de quitar:** Noticias, El Tiempo, Bing, Obtener ayuda, Centro de
  opiniones, el lanzador de Microsoft 365, Solitaire, Clipchamp, Power Automate,
  Dev Home, Películas y TV, Mapas, Cortana y las promociones preinstaladas
  (Spotify, Netflix, Disney+, Prime Video, TikTok, Candy Crush).
- **Opcionales:** Copilot, Outlook nuevo, Teams, To Do, Enlace Móvil, Notas
  rápidas, Grabadora, Reloj, Cámara, Reproductor multimedia, WhatsApp…
- **Con cuidado:** la app Xbox, Xbox Game Bar y el proveedor de identidad de
  Xbox. Se confirman una a una.

Si tu equipo usa una, sale marcada como **necesaria aquí**: Game Bar en un X3D
de dos CCD, la pila de Xbox si tienes juegos de Game Pass. La Tienda, la
Calculadora, Fotos o el Bloc de notas no se ofrecen.

Quitar una app la desinstala para todos los usuarios; **deshacer la reinstala
desde Microsoft Store** con winget. OneDrive también se puede desinstalar, salvo
que tus carpetas vivan dentro de él: entonces Win Juicer se niega y dice por
qué.

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

### Antes y después

Justo antes de aplicar el primer cambio, Win Juicer toma una **medida
inicial**: tiempo del último arranque (el que cronometra Windows), programas,
tareas y servicios de inicio, procesos y servicios en marcha, memoria en uso y
espacio libre. «Medir antes y después» (o `-Medir`) mide otra vez y lo compara,
en verde lo que ha mejorado. El arranque sólo cambia después de reiniciar, y la
memoria y los procesos dependen de lo que tengas abierto: lo justo es medir las
dos veces recién reiniciado y con todo cerrado (si no, lo avisa). «Nueva
medida inicial» empieza la comparación desde ahora.

### Exportar e importar

Como en WinUtil: *Exportar* guarda en un JSON lo que Win Juicer ha cambiado en
este equipo —ajustes, preferencias, apps quitadas y DNS— y en otro PC
*Importar* lo aplica, con el mismo motor y el mismo diario, así que también se
deshace. Lo que sólo tiene sentido aquí (programas de inicio, ajustes de un
`.exe`) no se exporta, y lo que no aplique en el otro equipo se salta y lo dice.

### Mantenimiento

Limpieza de temporales, informes de errores y descargas de Windows Update;
TRIM o desfragmentado según la unidad; limpieza de componentes; DISM + SFC;
restablecer la red (Winsock y TCP/IP) y Windows Update (su caché se renombra, no
se borra). Esto no se puede deshacer, así que sólo borra lo que Windows
regenera. **La caché de shaders y Prefetch no se tocan**: vaciarlas hace que la
siguiente partida tenga tirones.

## Lo que no hace, y por qué

No desactiva SysMain, ni el archivo de paginación, ni la compresión de memoria,
ni Defender, ni Windows Update, ni las mitigaciones de Spectre. No «libera RAM».
No borra la caché de shaders. No fuerza el HPET. No toca las claves «Games» de
MMCSS ni `Win32PrioritySeparation`. No limpia el registro. No quita todas las
apps de la Tienda de golpe ni desactiva servicios en masa. No desinstala Edge a
la fuerza. No desactiva IPv6 ni Teredo. No cambia el DNS «para bajar el ping».

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
- Antes de aplicar intenta crear un **punto de restauración**, y dice si
  Windows lo creó o no (sólo permite uno cada 24 horas).

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
  src/Native.ps1          SystemParametersInfo, modos de pantalla, Modern Standby, núcleos híbridos
  src/Hardware.ps1        de qué está hecho el equipo
  src/Advisor.ps1         qué conviene a este equipo, y por qué
  src/Audit.ps1           el diagnóstico
  src/Tuning.ps1          la revisión de hardware: BIOS, overclock, estabilidad
  src/Debloat.ps1         las apps que vienen con Windows, y OneDrive
  src/Network.ps1         DNS, restablecer la red y Windows Update
  src/Apps.ps1            instalar con winget
  src/Config.ps1          exportar e importar la configuración
  src/Measure.ps1         antes y después: medir y comparar
  src/Frames.ps1          FPS y frametimes con PresentMon
  src/Monitor.ps1         el monitor: EDID, FreeSync, VRR, HDR y consejos
  src/Limiter.ps1         limitador de FPS por juego
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

Las pruebas de `Windows.Tests.ps1` cambian de verdad la configuración del equipo,
nivel Extremo incluido, y luego la devuelven. Están pensadas para una máquina
desechable como la de CI, así que sólo se ejecutan en Windows, como
administrador **y** con `WINJUICER_PRUEBAS_REALES=1`. Sin esa variable se saltan.
