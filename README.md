# BT Juicer

Una sola app Android, sin Shizuku, sin root, sin permisos especiales. Mejora lo
que se puede mejorar en la escucha por Bluetooth y es honesta sobre lo que no.

---

## Lo primero: el códec

**Cambiar el códec Bluetooth requiere `BLUETOOTH_PRIVILEGED`**, de nivel
`signature|privileged`, que ninguna app instalable puede obtener:
`setCodecConfigPreference()` es `@SystemApi`. Eso no lo hace BT Juicer ni lo hará.

**Leerlo sí es posible**, por otra vía: `dumpsys bluetooth_manager` lo imprime,
y `dumpsys` sólo pide la autorización del usuario shell. BT Juicer se conecta al
servidor de depuración del propio teléfono —el mismo mecanismo que usa Shizuku,
pero integrado, sin segunda app— y pregunta desde ahí.

Resumiendo: **te dice qué códec y qué bitrate tienes de verdad; cambiarlo sigue
siendo cosa de opciones de desarrollador.** Lo que ganas es saber si lo que
configuraste quedó realmente aplicado, que es justo lo que Android no te enseña.

## Qué hace

### 1. Ecualizador

Aplicado a la sesión de audio 0 — la mezcla global del sistema — así que afecta
a **cualquier** app que suene, incluidas las de streaming con DRM cuyo audio no
se puede tocar de ninguna otra forma. El único permiso que necesita es
`MODIFY_AUDIO_SETTINGS`, que es normal.

**Modelo paramétrico.** Internamente la curva no son "diez mandos" sino una
lista de biquads —campana, shelf grave, shelf agudo, paso alto, paso bajo— con
frecuencia, ganancia y Q. Es el mismo lenguaje que habla cualquier ecualizador
paramétrico de escritorio, y el que publica AutoEq. Se renderiza sobre un banco
de 31 bandas de tercio de octava; si el HAL del teléfono no acepta tantas, baja
a 15 y luego a 10 antes de rendirse.

**Los mandos significan lo que dicen.** En la vista sencilla, los diez sliders
son *objetivos*, no ganancias de filtro. Un ecualizador gráfico corriente copia
el valor a cada banda y se pasa varios dB, porque las campanas vecinas suman:
pedir +3 dB en un rango ancho devuelve +4.7 dB reales. BT Juicer resuelve las
ganancias con iteración amortiguada hasta que la respuesta *combinada* cae sobre
el objetivo — error máximo medido de 0.012 dB frente a 1.74 dB del método
ingenuo.

**Importación de AutoEq.** AutoEq mide audífonos reales y publica la corrección
que los lleva a una curva objetivo. Se aceptan los dos formatos del proyecto,
`ParametricEQ.txt` y `GraphicEQ.txt`, pegando el texto o eligiendo el archivo.
Es, con diferencia, la mayor mejora disponible en un ecualizador: una corrección
derivada de una medición de tu modelo exacto, no mandos movidos a ojo. La app no
incluye datos de medición propios ni afirma nada sobre ningún audífono concreto.

**Gráfica de la respuesta.** Se dibuja la magnitud combinada real de la cadena.
Con diez campanas solapadas o treinta biquads importados, es la única forma
honesta de saber qué está haciendo el ecualizador. Los mandos mienten; la curva
no.

**Compresor multibanda.** Tres bandas con cuatro modos (desactivado, suave,
calle, noche). No es un truco de volumen: sube los pasajes bajos sin tocar los
picos, que es lo que hace que la música sobreviva al metro sin ir subiendo y
bajando el volumen. El grave siempre se comprime menos que el resto — aplastarlo
es la forma más rápida de que la música suene pequeña.

**Ganancia previa automática y limitador.** Subir bandas sube el nivel de pico y
todo lo que viene detrás satura. El botón «Automática» baja la ganancia justo lo
necesario para compensar el mayor realce, de modo que activar el ecualizador no
sea simplemente subir el volumen y creer que suena mejor.

**Perfiles por audífono.** Una corrección sólo es correcta para el audífono
sobre el que se midió; llevar la curva de un modelo a otro es peor que no
ecualizar. Cada perfil puede atarse a una dirección Bluetooth, y la app cambia
de curva sola en cuanto se conectan esos audífonos.

Detalle de dónde encaja todo esto: actúa **antes** del codificador Bluetooth.
Para ecualizar es exactamente lo correcto, y es también la razón por la que
ningún DSP aquí puede deshacer lo que el códec pierde después.

### 2. Panel de la salida activa

Ruta actual (A2DP, LE Audio, USB, cable, altavoz), nombre del dispositivo, si
está reproduciendo, frecuencia real del mezclador, tamaño de buffer y frecuencias
que acepta la salida. Todo con API pública.

Avisa además si el mezclador va por encima de 48 kHz con salida Bluetooth, que es
un remuestreo que no aporta nada.

### 3. Lectura en vivo del códec, vía ADB integrado

Emparejas una vez con el código de 6 dígitos de la depuración inalámbrica, desde
la propia app. A partir de ahí BT Juicer descubre por mDNS el puerto del demonio
ADB —cambia en cada reinicio— y lee el códec negociado: LDAC o AAC, la
frecuencia, la profundidad de bits y, con LDAC, el escalón de bitrate
(990 / 660 / 330 / adaptativo).

El emparejamiento es de una vez porque el demonio recuerda la clave, guardada en
el keystore de Android. Lo que se pierde al reiniciar es la conexión, no el
emparejamiento.

Avisa además cuando tus audífonos ofrecen LDAC y el enlace no lo está usando,
que casi siempre significa multipunto activo o LDAC apagado en la app del
fabricante.

Esta parte es **opcional**: sin ella el ecualizador y todo lo demás funcionan
igual.

### 4. Guía de los ajustes que la app no puede tocar

Cuatro pasos con acceso directo a la pantalla exacta del sistema: activar LDAC en
la app del fabricante, fijar el códec y los 990 kbps, poner 44.1 kHz, y eximir a
BT Juicer de la optimización de batería.

Como Android revierte solo la calidad de LDAC al reconectar, la app puede
**avisarte cuando se conecten unos audífonos** con un acceso directo a esa
pantalla. No puede comprobar el valor —eso es lo que exige el permiso de firma—
pero sí recordarte en el momento justo.

## Requisitos

- Android 9 (API 28) o superior.
- Permisos: `MODIFY_AUDIO_SETTINGS` (automático), notificaciones y dispositivos
  cercanos (opcionales; el ecualizador funciona sin ellos).

## Compilar

```
./gradlew assembleDebug
```

JDK 17+ y el SDK de Android (API 35). El APK queda en
`app/build/outputs/apk/debug/app-debug.apk`.

En Windows, si `gradlew.bat` se queja de `JAVA_HOME`:

```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
.\gradlew.bat assembleDebug
```

⚠️ Android Studio ofrecerá actualizar el plugin de Android. **Dile que no.** Ese
asistente sube AGP y Kotlin pero deja Compose y androidx atrás, y la compilación
deja de funcionar. Las versiones de `gradle/libs.versions.toml` son un conjunto
coherente: se suben todas a la vez o ninguna.

## Arquitectura

```
app/src/main/java/com/btjuicer/
  Juicer.kt                 singletons; no hay clase Application
  audio/Filters.kt          biquads, magnitud y ajuste de ganancias
  audio/AutoEq.kt           lectura de ParametricEQ.txt y GraphicEQ.txt
  audio/EqModel.kt          configuración, modos, presets
  audio/AudioEngine.kt      DynamicsProcessing (31 bandas + MBC + limitador)
  data/Profiles.kt          perfiles guardados y atados a un dispositivo
  bt/LinkMonitor.kt         ruta de audio y estado A2DP, sólo API pública
  adb/AdbBridge.kt          único punto de contacto con la librería ADB
  adb/AdbDiscovery.kt       mDNS: encuentra los puertos de emparejar y conectar
  adb/AdbKeys.kt            identidad RSA en el almacén privado de la app
  adb/SelfSignedCert.kt     certificado X.509 autofirmado, escrito en DER
  adb/CodecStatus.kt        modelo del códec y parser de dumpsys
  data/Prefs.kt             preferencias
  service/JuicerService.kt  servicio en primer plano; reengancha el efecto
  service/Notifications.kt  estado y recordatorio
  ui/                       Compose, Material 3
```

El servicio en primer plano no es decorativo: varias ROMs **desenganchan los
efectos de la sesión global** cuando la salida cambia entre altavoz y Bluetooth,
sin ninguna señal de que ha ocurrido. El servicio escucha los cambios de ruta y
vuelve a aplicar la curva; un ecualizador que deja de funcionar en silencio es
peor que no tener ninguno.

## Estado

Toda la lógica —motor de audio, monitor de salida, preferencias, perfiles,
servicio y ViewModel— está verificada con el compilador de Kotlin contra las
APIs reales de Android 15. La capa de Compose no pudo comprobarse en el entorno
donde se escribió.

La matemática del ecualizador va más allá: `Filters.kt` y `AutoEq.kt` son Kotlin
puro y **se ejecutaron** con casos numéricos. Campana, shelf grave, shelf agudo
y paso alto caen sobre su valor teórico; los parsers aceptan los dos formatos de
AutoEq y rechazan basura; y el ajuste de ganancias converge a 0.012 dB.

Lo primero que conviene mirar en el teléfono es la tarjeta de estado del
ecualizador: dirá si entró por `DynamicsProcessing`, si tuvo que caer al modo
compatible, o si la ROM lo rechazó del todo.

**Sobre `adb/AdbBridge.kt`**: la librería de ADB vive en JitPack, inalcanzable
desde donde se escribió este código, así que ese archivo —y sólo ese— está
escrito contra una API que no se pudo compilar ni verificar. Por eso es corto y
está aislado: si su forma real difiere, se corrige en un único sitio. El resto
del proyecto no depende de él para funcionar.

---

## Descarga

Cada push a `main` compila el APK en GitHub Actions y lo publica en la release
`latest`:

**https://github.com/Chomp-wq/BtJuicer/releases/tag/latest**

Descarga `BT-Juicer.apk` desde el navegador del teléfono y ábrelo para instalar.
No hace falta PC.
