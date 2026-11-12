# Win Juicer

Exprime Windows 11 para jugar y para cargar rápido, sin humo y con vuelta atrás.

La mayoría de «optimizadores» son una lista de claves de registro copiadas de
foros: la mitad no hace nada y la otra mitad rompe algo. Win Juicer hace lo
contrario. Cada ajuste dice **qué hace, qué ganas y qué te cuesta**, en ese
orden y sin adornos; ninguno se aplica sin que lo veas; y **todo se puede
deshacer**, uno a uno o de golpe, porque antes de tocar nada guarda cómo
estaba.

---

## Lo primero: lo que ningún programa puede arreglar

Las mayores pérdidas de rendimiento de un PC para juegos casi nunca están en el
registro de Windows. Están aquí:

- **La RAM sin su perfil XMP/EXPO.** Un kit DDR4-3600 funcionando a 2133, o un
  DDR5-6000 a 4800. Se activa en la BIOS.
- **Un solo módulo de RAM, o dos en el mismo canal.** La mitad de ancho de banda.
- **Un monitor de 144 Hz funcionando a 60.** Pasa muchísimo, y se arregla en
  Configuración en diez segundos.
- **Windows o la biblioteca de juegos en un disco duro mecánico.** Ningún ajuste
  compensa eso.
- **Un portátil jugando con batería**, o sin la gráfica dedicada.
- **Resizable BAR apagado** en la BIOS.

Por eso Win Juicer **empieza siempre analizando el equipo**, y no ofrece nada
hasta haberlo hecho.

## Primero, el análisis

Al abrirse, antes de enseñar ningún menú, recorre el equipo entero sin cambiar
nada:

| Qué mira | Para qué |
|---|---|
| **Procesador**: modelo, núcleos P y E, cachés L3 por CCD, 3D V-Cache, generación | Un Ryzen X3D de dos CCD necesita el plan Equilibrado; un Intel híbrido gana con la limitación de energía apagada; uno sin MBEC/GMET paga mucho más por la integridad de memoria |
| **Memoria**: módulos, ranuras, canales, velocidad frente a la estándar, paginación, compresión | Canal simple, dos módulos en el mismo canal, XMP/EXPO apagado, paginación en disco duro |
| **Gráficas y pantallas**: integrada o dedicada, VRAM, driver y su edad, HAGS, Resizable BAR, frecuencia actual y máxima de cada pantalla | HAGS sólo si la GPU la admite (imprescindible para DLSS FG), monitor a 60 Hz que da 144, portátil con dos gráficas |
| **Discos**: tipo (NVMe, SATA, disco duro), salud, espacio, dónde están Windows y cada biblioteca de juegos | Disco duro, SSD lleno, juegos en el disco lento, exclusiones de Defender donde más se notan |
| **Equipo y energía**: portátil o sobremesa, batería y su desgaste, Modern Standby, hibernación, plan activo | Plan propio en sobremesa, «Modo de energía» en Modern Standby, aviso si juegas con batería |
| **Seguridad**: VBS, HVCI, directivas, Defender u otro antivirus, BitLocker | Si la integridad de memoria ya está apagada, ni se ofrece |
| **Programas**: lanzadores, grabadores (OBS, NVIDIA App…), Discord, juegos TCP (WoW, FFXIV…), Outlook, WSL, Docker, Hyper-V, apps de la Tienda que avisan, anti-trampas, otros sistemas en el arranque | No toca el hipervisor si usas WSL o Docker, ni el indexado si tienes Outlook, ni el inicio rápido con arranque dual; Nagle sólo si tienes juegos TCP |
| **Tu configuración**: grabación en segundo plano, aceleración del ratón, Teclas especiales, Sensor de almacenamiento, programas de inicio, red (Wi-Fi o cable y a qué velocidad) | Respeta lo que usas; propone quitar del inicio sólo lo que se abre en segundos cuando lo necesitas |

Con eso hace dos cosas:

- **Lo que tienes que hacer tú**, por orden de importancia: lo que ningún
  programa puede cambiar (BIOS, cables, RAM, discos).
- **Un plan a medida**: cada ajuste del catálogo queda como *recomendado*,
  *opcional*, *desaconsejado en este equipo* o *no aplica*, siempre con el
  porqué de **tu** máquina («Tu Ryzen 9 7950X3D tiene dos CCD y…», «Tienes WSL y
  Docker Desktop, que dejaría de funcionar»). Si algo que se aplicó antes ya no
  te conviene, el plan propone deshacerlo. Lo que debilita la seguridad nunca
  se recomienda solo: como mucho es opcional, y lo decides tú.

El informe queda en `%ProgramData%\WinJuicer\informe.txt`, y todos los datos
en `equipo.json` junto a él.

## Cómo se usa

Descarga la carpeta `WinJuicer` y haz doble clic en **`WinJuicer.cmd`**. Pide
permisos de administrador, analiza el equipo, te enseña la ficha y lo que ha
encontrado, y abre el menú:

```
  1  Análisis del equipo      qué tiene y qué lo frena (no cambia nada)
  2  Plan a medida            lo que conviene a este equipo, y por qué
  3  Ajustes uno a uno        estado y consejo para este equipo
  4  Perfiles fijos           Seguro · Rendimiento · Extremo, adaptados
  5  Programas de inicio      lo que arranca solo con Windows
  6  Juegos                   GPU, prioridad y exclusiones de Defender
  7  Mantenimiento            limpieza, TRIM y reparación de Windows
  8  Deshacer                 todo, o cambio a cambio
  9  Lo que no hacemos        los «trucos» que circulan, y por qué no
  R  Volver a analizar        tras cambiar hardware, BIOS o programas
```

No instala nada, no se queda residente y no se conecta a internet. Funciona con
Windows PowerShell 5.1, la que ya trae Windows 11, y también con PowerShell 7.

### Desde la línea de órdenes

```powershell
.\WinJuicer.ps1 -Analizar                               # análisis, hallazgos y plan; no cambia nada
.\WinJuicer.ps1 -AplicarPlan -Simular                   # qué haría el plan a medida
.\WinJuicer.ps1 -AplicarPlan -ConInicio                 # aplicarlo, y quitar del inicio lo sugerido
.\WinJuicer.ps1 -AplicarPlan -Incluir ui.menu,red.nagle # con opcionales añadidos
.\WinJuicer.ps1 -Lista                                  # todos los ajustes y su estado
.\WinJuicer.ps1 -Perfil Rendimiento                     # perfil fijo, sin lo desaconsejado aquí
.\WinJuicer.ps1 -Aplicar juegos.ventana,ui.menu -Si     # ajustes concretos, sin preguntar
.\WinJuicer.ps1 -Deshacer ui.menu
.\WinJuicer.ps1 -DeshacerTodo
```

Los ajustes del nivel Extremo se confirman siempre uno a uno escribiendo «SI»;
sin preguntas, sólo con `-AceptoRiesgos`. Código de salida: 0 si todo fue bien,
1 si algún ajuste falló, 2 si un argumento no es válido.

## Los tres perfiles

Para quien prefiera no ir ajuste a ajuste. Cada nivel incluye los anteriores, y
se aplica **sin lo que el análisis desaconseja en tu equipo**.

| Perfil | Qué cuesta |
|---|---|
| **Seguro** | Nada que nadie vaya a echar de menos. Incluye las reparaciones. |
| **Rendimiento** | Batería, estética o funciones que no todo el mundo usa: grabación de Game Bar, Widgets, animaciones. |
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

El plan propio tiene un GUID fijo: ejecutar la herramienta dos veces no crea
dos planes, y deshacer lo borra.

### Juegos

| Ajuste | Nivel | Impacto |
|---|---|---|
| Modo juego | Seguro | Bajo |
| Programación de GPU acelerada por hardware | Seguro | Bajo |
| Optimizaciones para juegos en ventana (modelo flip en DX10/11) | Seguro | Medio |
| Reserva multimedia para segundo plano al 10 % | Seguro | Bajo |
| Sin grabación en segundo plano de Xbox Game Bar | Rendimiento | Medio |
| Sin aceleración del ratón | Rendimiento | Bajo |
| Sin atajos de Teclas especiales (Mayús ×5) | Rendimiento | Bajo |

Y por juego, desde el menú **Juegos**:

- **GPU de alto rendimiento** para un `.exe`: en portátiles con dos gráficas,
  que no arranque en la integrada.
- **Prioridad de CPU alta** para un `.exe`.
- **Exclusiones de Microsoft Defender** para las bibliotecas de Steam, Epic,
  GOG y Xbox, que detecta solas. Es lo que más acorta las cargas de todo lo que
  Win Juicer puede tocar, y por eso es Extremo: un archivo malicioso dentro de
  esa carpeta no se analizaría al abrirse.

### Interfaz

| Ajuste | Nivel | Impacto |
|---|---|---|
| Sin apps promocionadas que Windows instala solo | Seguro | Bajo |
| Sin animaciones | Rendimiento | Medio |
| Sin transparencias | Rendimiento | Bajo |
| Menú contextual clásico | Rendimiento | Bajo |
| Búsqueda de Inicio sin resultados de Bing | Rendimiento | Medio |
| Sin Widgets | Rendimiento | Bajo |

Las animaciones y la interfaz no dan FPS: hacen que Windows *se sienta* más
rápido, que también cuenta.

### Segundo plano, disco y red

| Ajuste | Nivel | Impacto |
|---|---|---|
| Servicio de telemetría (DiagTrack) deshabilitado | Seguro | Bajo |
| Apps de la Tienda sin segundo plano | Rendimiento | Bajo |
| Sin instantáneas de Recall (PC Copilot+) | Rendimiento | Bajo |
| Sin nombres cortos 8.3 en NTFS | Rendimiento | Bajo |
| Sin fecha de último acceso en NTFS | Rendimiento | Bajo |
| Sin algoritmo de Nagle (sólo juegos TCP, como los MMO) | Rendimiento | Bajo |
| Sin indexado de búsqueda | Extremo | Bajo |

### Seguridad: ganancias reales, costes reales

| Ajuste | Impacto |
|---|---|
| Desactivar la integridad de memoria (HVCI) | Alto |
| No arrancar el hipervisor (apaga VBS entero; rompe WSL 2, Hyper-V, Sandbox, Docker) | Medio |

Microsoft reconoce el coste de la integridad de memoria en juegos y propone
desactivarla a quien priorice jugar. Win Juicer lo ofrece, explica qué pierdes,
y no lo aplica sin que escribas «SI». Si BitLocker está activo, lo suspende
durante un reinicio antes de tocar la configuración de arranque, para que no te
pida la clave de recuperación.

### Programas de inicio

Lista lo que arranca con Windows —registro, carpetas de Inicio y tareas
programadas de terceros— y lo activa o desactiva con el mismo interruptor que
usa el Administrador de tareas. No borra nada.

### Mantenimiento

Limpieza de temporales, informes de errores y descargas de Windows Update;
TRIM o desfragmentado según la unidad; limpieza de componentes; y DISM + SFC.
Esto no se puede deshacer, así que sólo borra lo que Windows regenera. **La
caché de shaders y Prefetch no se tocan**: vaciarlas hace que la siguiente
partida tenga tirones.

## Lo que no hace, y por qué

No desactiva SysMain, ni el archivo de paginación, ni la compresión de memoria,
ni Defender, ni Windows Update, ni las mitigaciones de Spectre. No «libera RAM».
No borra la caché de shaders. No fuerza el HPET. No toca las claves «Games» de
MMCSS ni `Win32PrioritySeparation`. No limpia el registro. No desinstala apps en
bloque ni desactiva servicios en masa. No cambia el DNS «para bajar el ping».

Cada una de estas cosas tiene su explicación en el menú **Lo que no hacemos**.
Resumen: o no hacen nada medible, o rompen algo, o las dos cosas. Varias, de
hecho, las **deshace** Win Juicer si otro programa las dejó puestas.

## Cómo deshace

Antes de cambiar nada, cada ajuste guarda en
`%ProgramData%\WinJuicer\diario.json` el valor exacto que había: si una clave no
existía, si un servicio estaba en automático retrasado, qué plan de energía
estaba activo. El diario se escribe *antes* de aplicar, para que ni un corte de
luz a medias deje el equipo sin vuelta atrás.

- **Deshacer** devuelve cada ajuste a como estaba antes de que Win Juicer lo
  tocara **por primera vez**, aunque lo hayas aplicado varias veces.
- Las claves que Win Juicer creó se borran al deshacer, salvo que otro programa
  haya escrito en ellas después.
- Cada ajuste se aplica entero o no se aplica: si una parte falla, lo ya hecho
  se revierte en el momento.
- Si Windows no conserva un cambio, se dice en lugar de darlo por bueno.
- Antes de aplicar un perfil intenta crear un **punto de restauración**, y dice
  si Windows lo creó o no (sólo permite uno cada 24 horas).

El registro de lo que se hizo, con fecha, queda en
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
  src/Backend.ps1         único punto que toca registro, servicios y programas del sistema
  src/Engine.ps1          estado, aplicar, verificar, deshacer y el diario
  src/Catalog.ps1         los ajustes, con su texto, su consejo según el equipo, y los mitos
  src/Native.ps1          SystemParametersInfo, pantallas, núcleos P/E y CCD, Modern Standby
  src/Inventory.ps1       el análisis del equipo, y los clasificadores de hardware y software
  src/Advisor.ps1         hallazgos, veredicto de cada ajuste y el plan a medida
  src/Startup.ps1         programas de inicio
  src/Games.ps1           bibliotecas de juegos y ajustes por ejecutable
  src/Maintenance.ps1     limpieza y mantenimiento
  src/Console.ps1         menús y pantallas
  tests/                  Pester
```

Todo lo que toca la máquina pasa por `Backend.ps1`, que tiene una versión en
memoria. Así el motor y **cada uno de los ajustes del catálogo** se prueban sin
Windows: se aplican sobre una máquina simulada —con los destrozos típicos de
otros optimizadores ya hechos— y se comprueba que deshacer la deja idéntica,
byte a byte.

El análisis y el asesor están separados por la misma razón: recoger datos sí
habla con Windows, pero decidir qué conviene sólo lee el perfil del equipo. Las
pruebas montan equipos inventados —un sobremesa con Ryzen 9 7950X3D, un portátil
con Modern Standby, batería y dos gráficas, un equipo con disco duro y Outlook,
uno con WSL y Docker, uno con arranque dual…— y comprueban el consejo que recibe
cada uno.

## Estado

Escrito y probado en Linux con PowerShell 7 y Pester: el motor, el diario, el
catálogo entero en ida y vuelta, el gestor de inicio, los ajustes por juego, los
clasificadores de hardware y software, y el consejo que recibe cada uno de una
docena de equipos inventados. El análisis estático comprueba que el código es
válido en Windows PowerShell 5.1.

En GitHub Actions corre además sobre Windows Server 2025 (compilación 26100, la
misma base que Windows 11 24H2), en 5.1 y en 7, contra el registro, los
servicios, powercfg y bcdedit de verdad: hace el análisis completo de la máquina
del runner sin un solo error, aplica su plan a medida y los tres niveles
completos, lo deshace todo y comprueba que no queda rastro.

Lo que una máquina virtual no tiene no se ha podido probar en ningún sitio: una
pantalla y una gráfica reales, batería y Modern Standby, BitLocker, y la
hibernación (la VM no la admite, así que de «Inicio rápido» sólo se ha probado
que, al fallar, deja todo como estaba). Es lo primero que conviene mirar en un PC
de verdad, empezando por el análisis, que no cambia nada.

## Pruebas

```powershell
Invoke-Pester ./WinJuicer/tests
```

Las pruebas de `Windows.Tests.ps1` cambian de verdad la configuración del equipo,
nivel Extremo incluido, y luego la devuelven. Están pensadas para una máquina
desechable como la de CI, así que sólo se ejecutan en Windows, como
administrador **y** con `WINJUICER_PRUEBAS_REALES=1`. Sin esa variable se saltan.
