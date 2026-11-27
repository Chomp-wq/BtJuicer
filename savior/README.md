# Secret Savior

Bloqueo de pornografía para Android pensado para quien quiere dejarlo: **una vez
activado no se puede desactivar desde el teléfono.** La decisión se toma una vez,
con la cabeza fría, y deja de ser una decisión que haya que volver a ganar cada
noche.

Módulo `:savior` de este repositorio (`com.secretsavior`). Sin servidores propios,
sin cuentas, sin anuncios, sin telemetría.

## Cómo funciona

Varias capas, cada una cubre un hueco de la anterior. Las marcadas «opcional» se piden
aparte porque necesitan ADB una sola vez.

| Capa | Qué hace |
|---|---|
| **Filtro DNS** (`VpnService` local) | Captura las consultas DNS del teléfono. Los dominios de la lista local (palabras clave, TLD `.xxx/.porn/.sex/.adult`, ~70 sitios y CDN, redes de anuncios para adultos) reciben `0.0.0.0`. El resto se reenvía a **CleanBrowsing Adult Filter** (185.228.168.10), que bloquea pornografía y fuerza búsqueda segura (deja pasar sitios mixtos como Reddit: ahí actúa el guardián); Cloudflare for Families (1.1.1.3) queda de reserva. Se usan también sus direcciones IPv6. Además **captura por IP los resolutores públicos conocidos** (Google, Cloudflare, Quad9, OpenDNS, AdGuard, NextDNS, Mullvad…): el DNS clásico a esas IP, también **por TCP**, se filtra aquí mismo; DoH, DoT y QUIC a esas IP se rechazan al instante (RST o «puerto inaccesible») para que la app vuelva al DNS del sistema; el ping (ICMP) a ellas se contesta en el túnel. Los proveedores de DNS cifrado por nombre también se bloquean. No pasa tu tráfico por ningún servidor. |
| **Guardián** (`AccessibilityService`) | Reconoce las pantallas peligrosas **en cualquier idioma**: no se fía de una sola traducción, sino de la clase de la ventana, los ids de las vistas, una tabla de 27 idiomas y los textos que lee de los propios Ajustes. En un idioma que no conoce pasa a modo estricto. **Tapa antes de leer**: una capa cubre la pantalla hasta haberla leído, de modo que un toque rápido no llega a «Forzar detención». Vigila la ficha de la app (también la de Seguridad de Xiaomi), desinstalar, administradores, accesibilidad, VPN, DNS privado, **proxy manual de Wi-Fi**, **usuarios y segundo espacio**, restricciones de batería en segundo plano, autoinicio, opciones de desarrollador (si se cerraron) y el gestor de apps activas de Android 13+. Cierra el navegador si apunta a un sitio bloqueado y **falla cerrado**: si el filtro está caído, los navegadores no funcionan hasta repararlo. Cierra el texto explícito que se escribe, sólo en navegadores, buscadores (Google, YouTube), Telegram y Reddit. **Cierra al abrirse** X / Twitter, Tor Browser, Orbot y Aloha. Tocar una capa o que el guardián cierre una pantalla peligrosa cuenta como intento: durante 30 s Ajustes, el instalador y la app de Seguridad se cierran en cuanto se abren. Instalar una actualización se deja pasar. |
| **Administrador del dispositivo** | Mientras la app sea administradora, Android se niega a desinstalarla. Se pide **el último**, con «Activar y bloquear». |
| **Siempre activo** | El filtro va como servicio en primer plano con notificación fija. Si el sistema lo mata, una alarma lo levanta en segundos. La pantalla principal guía el autoinicio de Xiaomi, la exclusión de batería, «VPN siempre activa» y «Pausar la actividad si no se usa». |
| **Vigilante** | Cada 10 s, al arrancar y al caerse el filtro, levanta lo que falte; si otra VPN le quita el permiso o se retira un permiso, trae la app al frente. |
| **Resurrección** (acceso a notificaciones) | Un `NotificationListenerService` que **no lee ninguna notificación**. Tras forzar la detención, Android vuelve a enlazar los oyentes aprobados, lo que arranca el proceso y, con él, el vigilante, el filtro y la autocuración. |
| **Autocuración** (opcional, `WRITE_SECURE_SETTINGS`) | Con ese permiso concedido una vez por ADB, la app vuelve a escribir su propia entrada en `enabled_accessibility_services` (Android la borra al forzar la detención), deshace el DNS privado estricto y, si se cerraron, las opciones de desarrollador y ADB. Observa esos ajustes: el cambio se deshace al instante. |
| **Propietaria del dispositivo** (opcional, ver abajo) | La versión dura: Android impide **forzar la detención y borrar los datos** de la app, el modo seguro, el restablecimiento desde Ajustes, otros usuarios y perfiles, y cambiar la VPN o el DNS privado; la app no se puede desinstalar, y queda como VPN siempre activa. Si la protección lleva ≥ 20 s rota, **suspende los navegadores** hasta repararla. Oculta X. Opcionalmente prohíbe también ADB. |
| **Endurecimientos de ida** | «Cerrar opciones de desarrollador» (la vía de ADB; también deja sin depuración inalámbrica a BT Juicer) y, como propietaria, «Prohibir ADB para siempre». Como todo lo demás, sólo se pueden encender. |

El bloqueo no se guarda sólo en las preferencias de la app: si alguien borra los
datos, el administrador sigue activo en el sistema y la app lo detecta como
«bloqueada».

**X / Twitter** se bloquea entera: sus dominios (`twitter.com`, `x.com`, `t.co`,
`twimg.com`…) en el filtro DNS, y la app (`com.twitter.android`) se cierra en cuanto
se abre.

Dentro de la app, con el bloqueo activo: contador de días, botón **«Tengo ganas
ahora mismo»** (respiración 4-7-8 y tu propia razón, escrita por ti), y añadir más
sitios a la lista (sólo se puede añadir, nunca quitar). No hay ninguna acción de
apagar en el código.

## Novedades de la 4.0

Motivo: en un Xiaomi, **«Forzar detención» bastaba para apagarlo todo.** Android saca entonces a
la app de Accesibilidad, cancela sus alarmas, tira la VPN y deja el paquete «detenido», sin que le
llegue nada hasta que alguien la abra. El guardián intentaba cerrar la pantalla antes de que se
pudiera pulsar, pero eso es una carrera, y en MIUI la ficha de la app vive en la app de Seguridad.

- **Forzar detención en modo normal: se recupera en segundos.** El acceso a notificaciones
  (`ReviveListener`) hace que Android vuelva a enlazar la app tras forzar su detención; al arrancar
  levanta el filtro y el vigilante, y la autocuración (si se concedió `WRITE_SECURE_SETTINGS`)
  vuelve a encender la accesibilidad. Sigue habiendo una ventana de unos segundos sin protección.
  Depende de que el sistema reenlace el oyente (y en Xiaomi, del autoinicio): hay que comprobarlo en
  cada teléfono.
- **Forzar detención en modo propietaria del dispositivo: imposible.** El botón queda inutilizado
  (`setUserControlDisabledPackages`, Android 11+).
- **Cambiar el idioma ya no sirve para saltarse el guardián.** Antes reconocía las pantallas por
  sus textos en unos pocos idiomas. Ahora usa la clase de la ventana, los ids de las vistas, una
  tabla de 27 idiomas y los textos que lee de Ajustes. Y la pantalla se tapa hasta haberla leído.
- **DNS cifrado a una IP.** Un navegador con «DNS seguro personalizado» hacia `https://1.1.1.1/dns-query`
  no tiene nombre que bloquear. Ahora esas IP (y las de decenas de resolutores públicos) van al túnel
  y allí se filtran o se rechazan, y el navegador vuelve al DNS del sistema.
- **Apps con DNS fijo** (8.8.8.8 en el código): su consulta a un resolutor público conocido también
  cae en el túnel y se filtra.
- **Navegadores desconocidos.** La lista fija se completa preguntando al sistema qué apps abren una
  dirección web, y se refresca al instalar o actualizar una. Hace falta `<queries>` en el manifiesto.
- **Proxy de Wi-Fi** (resuelve el DNS fuera del teléfono): se cierra el editor del proxy manual y el campo de proxy automático (PAC), y el **editor de APN** (su campo «Proxy» pone un proxy del sistema para datos móviles).
- **Segundo espacio y usuarios** (también el «Segundo espacio» de Xiaomi): se cierran; como
  propietaria, se prohíben.
- **Restricciones de batería de Xiaomi** (`com.miui.powerkeeper`) y su autoinicio: la pantalla se
  cierra salvo con la ventana de gracia abierta desde la propia app.
- **Fallo de la configuración inicial.** Activar el administrador en el paso 3 bloqueaba la app a
  mitad de la configuración, y se saltaban la frase de compromiso y el paso de autoinicio de Xiaomi.
  Ahora **el administrador se pide el último**, con «Activar y bloquear», y hasta entonces nada
  queda fijo.
- **Apps bloqueadas:** X / Twitter, Tor Browser, Orbot y Aloha se cierran al abrirse. Como
  propietaria, X se oculta.

## Rendimiento

El filtro no debe notarse. Lo que hace para conseguirlo:

- **Sólo pasa el DNS por el túnel.** El resto del tráfico (webs, vídeo, descargas)
  sale por Wi-Fi o datos como siempre, sin tocarlo.
- **Las consultas no hacen cola.** Un único socket y un hilo que recibe; cada
  consulta sale al momento aunque haya cientos en vuelo. Se pregunta a los dos
  servidores de CleanBrowsing a la vez y gana el primero, así que un paquete perdido
  en datos móviles no cuesta segundos. Sin respuesta en 0,8 s se reintenta en todos;
  si CleanBrowsing falla seguido, durante 30 s se pregunta también a Cloudflare desde
  el principio.
- **IPv4 e IPv6 a la vez.** En redes móviles sólo IPv6 la IPv4 pasa por una
  traducción que añade latencia; preguntando también por IPv6 gana el camino directo.
- **La ronda periódica no despierta al teléfono** con la pantalla apagada: se entrega
  al despertar. Sólo el regreso tras cerrar la app usa una alarma que despierta.
- **La app enseña el tiempo medio del DNS** en «Estado». Si pasa de ~250 ms, lo
  lento es la red o la distancia al resolutor, no el teléfono.
- **Lo bloqueado se contesta en el teléfono**, sin salir a la red; la búsqueda es por
  sufijos en un conjunto, no recorriendo listas.
- **El túnel no gira en vacío.** El descriptor de la VPN es bloqueante: el hilo
  lector duerme hasta que llega una consulta, en vez de preguntar sin parar.
- **Android sólo genera los eventos que hacen falta.** Con una app no vigilada
  delante (WhatsApp, juegos, Instagram) el guardián pide únicamente los cambios de
  ventana, y las apps dejan de construir un evento por cada cosa que se mueve en
  pantalla. Los cambios de contenido y el texto escrito se piden sólo con un
  navegador, un buscador, Telegram, Reddit o Ajustes delante.
- **El autoencendido, fijado.** En Xiaomi, apagar el autoencendido de una app la detiene
  a la fuerza y Android desactiva su accesibilidad: no hay forma de reencenderlo después.
  Se probó tapar el interruptor con una capa transparente, pero la lista se reordena con
  una animación y tocando rápido se ganaba la carrera. Por eso: la configuración inicial
  exige abrir la pantalla de autoencendido y comprobar que Secret Savior está activado
  (el guardián lo detecta solo), y con el bloqueo activo esa pantalla se cierra entera
  cada vez que se abre. Consecuencia: no se puede gestionar desde ahí el autoencendido
  de otras apps; hay que hacerlo antes de activar. En otras marcas no se pide ni se cierra
  nada.
- **Las apps de seguridad del fabricante no se frenan.** Las de optimización
  (Seguridad de Xiaomi, Device Care de Samsung...) cambian de contenido sin parar
  mientras analizan o limpian. El guardián sólo las mira al abrirse una pantalla nueva
  y sólo cierra la ficha de desinstalar, parar o borrar datos de Secret Savior; que la
  lista del optimizador nombre la app ya no basta.
- **El guardián no frena otras apps.** Descarta al instante los eventos de las apps
  que no vigila, sin pedirles nada. En navegadores lee la barra de direcciones por su
  id (una consulta) con un temporizador, no con eventos, y en Ajustes revisa la pantalla
  como mucho dos veces por segundo.
- **Caché DNS local.** Lo ya preguntado se contesta al momento, sin ir a CleanBrowsing.
  Si la respuesta caducó se sirve igualmente (con un TTL corto) y se renueva en segundo
  plano, y la que está a punto de caducar se renueva antes de hacerlo. Las respuestas
  negativas no se sirven caducadas, y al cambiar de red se olvidan las caducadas: lo que
  contestó otra red (un Wi-Fi de hotel que secuestra el DNS) no se reutiliza al salir.
- **Cambio de red sin esperas.** Al pasar de Wi-Fi a datos (o al revés) las consultas en
  vuelo se reenvían al instante: las que salieron por la red vieja nunca van a contestar
  y, sin esto, cada una esperaría a la escalada de 0,8 s.
- **El guardián sólo pide lo imprescindible.** Cambios de ventana siempre; texto escrito sólo
  con un navegador, YouTube/Google, Telegram o Reddit delante; cambios de contenido, sólo en
  las pantallas de Ajustes del sistema.
  En navegadores relee la barra de direcciones cada 1,5 s, y cada 10 s con la pantalla
  apagada, cuando no puede haber nada nuevo que ver.
- **Prioridad de los hilos del DNS.** El lector del túnel y el receptor de respuestas
  (y los hilos de DNS por TCP) corren con prioridad de primer plano: todas las conexiones
  del teléfono esperan por ellos y no deben perder la CPU frente a trabajo en segundo plano.
- **Release, no depuración.** CI publica la compilación **release** (R8 activado, no
  «debuggable»): una app depurable corre con menos optimización de ART y el DNS y el guardián lo
  notan. Va firmada con la clave de depuración fija, así que se instala encima de la anterior.
- **Un solo recorrido por pasada.** El guardián recorre la ventana una vez y recoge todo lo que
  necesita (textos, ids, barra de direcciones) en lugar de un recorrido por cada pregunta.
- **Autómata Aho–Corasick** para reconocer las frases de los 27 idiomas: una sola lectura de cada
  texto, sin importar cuántas frases haya.
- **Precarga del árbol en Android 13+** (`FLAG_PREFETCH_DESCENDANTS_HYBRID`): menos viajes entre
  procesos que pedir nodo a nodo.
- **Comprobación del administrador en caché** (es una llamada entre procesos y se pedía en cada
  evento) y **memoria del filtro DNS** de los dominios ya decididos.

Lo que no depende de la app: la primera visita a cada dominio espera la respuesta de
CleanBrowsing, que según dónde estés puede estar más lejos que el DNS de tu
operador. Android guarda las respuestas en caché, así que sólo se nota la primera vez.

## Mejoras de la 2.3

- **La VPN bloqueaba todo el IPv6 del teléfono.** El túnel sólo declara IPv4, y Android, ante
  una VPN sin dirección, ruta ni DNS de una familia, da por hecho que no la soporta y bloquea
  ese tráfico para todas las apps (`VpnService.Builder.allowFamily`). Ahora se permiten las dos
  familias y el IPv6 sale por la red de siempre. En redes móviles sólo IPv6 esto obligaba a
  todo a pasar por la traducción a IPv4 (464XLAT).
- **Búsqueda segura forzada en el propio filtro**, sin depender del resolutor: Google (todos
  sus dominios de país), Bing, DuckDuckGo y Yandex se resuelven por su nombre de búsqueda
  segura (`forcesafesearch.google.com`, `strict.bing.com`, `safe.duckduckgo.com`,
  `familysearch.yandex.ru`). Los buscadores sirven las miniaturas desde sus propios servidores,
  así que sin esto se ve contenido para adultos sin tocar un dominio bloqueado. Si el nombre
  seguro no resuelve, el buscador falla; nunca se sirve sin filtrar. YouTube queda fuera: su
  modo restringido esconde mucho contenido corriente.
- **Firefox no activa DNS cifrado por su cuenta:** su dominio canario
  (`use-application-dns.net`) se contesta «no existe», que es la señal que espera.
- **Más proveedores de DNS cifrado bloqueados** (los de las listas de «DNS seguro» de los
  navegadores) y unos 60 sitios más en la lista local.
- **Los sitios de ayuda no se cierran por su título.** Un artículo de un sitio de la lista
  blanca (p. ej. `fightthenewdrug.org/how-porn-…`) ya no hace saltar al guardián.
- **La ventana de gracia ya no depende de la hora del teléfono** (atrasando el reloj se quedaba
  abierta), el contador de bloqueos no pierde lo último al cerrarse el proceso y el filtro
  vuelve también tras el «arranque rápido» de algunos fabricantes.

## Seguridad de la red: lo que se revisó y se corrigió

Una VPN que se equivoca afecta a todo el teléfono, no sólo a la app. Fallos reales que se
encontraron y corrigieron (cada uno con su prueba; el primero se reprodujo contra el
código anterior):

- **Respuestas DNS cruzadas.** Se preguntaba a varios servidores a la vez y las respuestas
  repetidas llegaban tarde; una podía coincidir con el identificador (16 bits) de OTRA consulta
  en vuelo y entregarse como suya. El cliente la descarta por no ser su pregunta y espera 5 s a
  una respuesta que ya nadie le manda: páginas que a veces tardan segundos en abrir. Ahora una
  respuesta sólo vale si viene de un servidor al que se preguntó, es de la misma pregunta
  (nombre, tipo y clase, sin distinguir mayúsculas) y todavía hay quien la espera; si no lo es,
  no gasta la consulta.
- **Respuestas cortadas (TC).** Cuando el resolutor cortaba una respuesta, la búsqueda fallaba. Ahora
  se repite por TCP contra quien contestó y se entrega completa; en la 4.0 el túnel además atiende
  él mismo el DNS por TCP.
- **Choque de subredes.** El túnel usaba siempre 10.255.255.0/24; si el Wi-Fi o la red del operador
  usaba esa subred, el teléfono dejaba de ver a su propio router. Ahora se mira qué redes hay en
  uso y se elige una libre (10.255.255 → 172.31.255 → 198.18.255 → 192.0.2).
- **Socket de reenvío roto.** Si el sistema lo cerraba (p. ej. al cambiar de red), el hilo
  receptor giraba al 100 % de un núcleo y el DNS no volvía. Ahora espera, y crea otro.
- **Un paquete raro tumbaba la VPN.** Cualquier excepción al leer un paquete cerraba el túnel y
  lo rehacía, lo que corta todas las conexiones del teléfono. Ahora se descarta el paquete.
- **Reenviador que no arranca.** Dejaba la VPN activa pero sin DNS, y todas las consultas se
  perdían. Ahora no se levanta el túnel y se reintenta a los 30 s.
- **Guardián en Play Store y Ajustes.** Se recorría la ventana en cada desplazamiento. Ahora sólo
  en los primeros 4 s tras abrir una pantalla, y la tienda ya no se vigila.
- **Avisos cada minuto.** Si el filtro caía (otra VPN, permiso retirado) la app saltaba encima de
  lo que se hiciera cada minuto, también en una llamada. Ahora el primer aviso es inmediato y los
  siguientes se espacian (1, 3, 10 y 30 min).

La pantalla principal muestra el tiempo medio del DNS y avisa cuando más de la mitad de las
últimas consultas se quedan sin respuesta.

### Límites que no son fallos de código

- **Nombres de la red local.** Todo el DNS va a resolutores públicos, así que lo que sólo
  resuelve el DNS de la red (`router.lan`, intranets, algunos portales de Wi-Fi) no se encuentra.
  Las IP directas funcionan. No se reenvía al DNS de la red porque eso abriría un resquicio:
  sería la forma de saltarse el filtro.
- **Redes que bloquean DNS externo** (hoteles, trabajo, colegio, algún operador): sin respuesta
  de los resolutores no hay DNS. Es lo esperado de un bloqueo que «falla cerrado».
- **Acceso a la red de la app.** El DNS de todo el teléfono pasa por esta app: si se le quita el
  acceso a datos o a Wi-Fi (p. ej. en Seguridad → Uso de datos), esa red se queda sin DNS.
- **Otra VPN.** Sólo cabe una a la vez. Con otra activa, los navegadores se cierran hasta
  recuperar el filtro.
- **Conexiones largas.** Cada vez que el sistema mata la app y la VPN se rehace, las conexiones
  abiertas (llamadas, descargas) se cortan un instante; por eso se evita todo reinicio evitable.

## Instalar

CI publica `Secret-Savior.apk` (release) en la release `latest`. En Android 13+, si lo instalas
a mano: **Información de la app → ⋮ → Permitir ajustes restringidos** antes de activar la
accesibilidad. La app te guía en pasos y exige escribir una frase de compromiso antes de activar;
el administrador se pide al final.

### Actualizar desde la 3.x

Se instala encima (misma clave de firma). Las piezas nuevas no se conceden solas. Si ya estaba
bloqueada, concédelas desde los botones de la pantalla principal, que abren una **ventana de
gracia** breve (2 minutos) sólo para esa pantalla: acceso a notificaciones, batería, VPN siempre
activa y «Pausar la actividad si no se usa». Cada ventana abre sólo su clase de pantalla (la de notificaciones no deja ver la VPN ni la batería, y al revés) y nunca deja ver la ficha de la app con
sus botones, el administrador, Accesibilidad ni la desinstalación.

**No actives «Bloquear conexiones sin VPN»**: el túnel sólo lleva DNS y el teléfono se quedaría
sin internet. La app avisa si está activado.

### Autocuración (opcional, recomendada)

Un permiso que se concede una vez por ADB:

```
adb shell pm grant com.secretsavior android.permission.WRITE_SECURE_SETTINGS
```

O sin ordenador, con el botón «Autocuración» de la app (depuración inalámbrica: el código de
vinculación se escribe en una notificación con campo de respuesta).

### Propietaria del dispositivo (opcional, de ida)

Quita la pega de forzar la detención y del modo seguro, pero **sólo se deshace restableciendo de
fábrica desde recovery**. Requisitos:

- Quitar temporalmente **todas** las cuentas (Ajustes → Cuentas: Google, Xiaomi y las de apps
  como WhatsApp o Telegram).
- Sin «Segundo espacio» ni «Apps duales» ni usuarios extra. **Bórralos antes de bloquear:** con el bloqueo activo esa pantalla se cierra y ya no se puede abrir, así que con uno existente no se puede hacerla propietaria desde el teléfono.
- En Xiaomi, activar «Depuración USB (ajustes de seguridad)» en Opciones de desarrollador.

```
adb shell dpm set-device-owner com.secretsavior/.guard.AdminReceiver
```

Desde la configuración inicial, «Activar con blindaje total» (junto a «Activar y bloquear», con los
mismos requisitos y la misma confirmación) lanza este camino en vez del diálogo de administrador:
al ser propietaria Android activa el administrador y eso bloquea. Hazlo antes de bloquear, mientras
las cuentas y el Segundo espacio aún se pueden quitar.

También sin ordenador desde la app («Blindaje total»). Después, volver a añadir las cuentas.

## Lo que no hace (honestidad)

Ningún bloqueo en el propio teléfono es imposible de quitar, y esta app no finge lo contrario:

- **Restablecer de fábrica desde recovery** lo quita siempre, también como propietaria.
- **Sin propietaria del dispositivo:**
  - **Modo seguro** (mantener «Apagar»): no corre ninguna app de terceros, y desde Ajustes se puede
    quitar el administrador y desinstalar.
  - **ADB**: con un ordenador se puede apagar el guardián o quitar el administrador. Sólo lo cierran
    las opciones de desarrollador cerradas (de ida) o, como propietaria, la prohibición de ADB.
  - **Forzar detención**: queda una ventana de unos segundos hasta la resurrección. Ésta depende de
    que el sistema reenlace el oyente de notificaciones y, en Xiaomi, del autoinicio; **hay que
    verificarlo en el propio teléfono**, no está garantizado en todas las ROM.
  - Crear otro usuario o invitado: da un espacio sin filtro (el guardián cierra esas pantallas).
- **DoH/DoT a IP que no están en la lista** de resolutores conocidos no se captura.
- **Proxies configurados dentro de apps**, y navegadores con proxy o VPN propios (el de Opera, por
  ejemplo), sacan el DNS del teléfono. Una VPN ajena le quita el puesto a la nuestra y los
  navegadores se cierran hasta recuperarlo.
- El filtro de URL del guardián sólo entiende las barras de direcciones de navegadores conocidos;
  la lista de palabras es amplia pero no perfecta.
- **No filtra imágenes ni vídeo dentro de apps** (redes sociales, etc.): bloquea sitios y búsquedas,
  no lo que una app decida mostrar.
- **Netflix** se excluye del túnel por completo (su DNS incluido): detecta cualquier VPN y se niega a
  reproducir si no. No es una vía de pornografía.
- **Quien controle el repositorio puede saltarse el bloqueo.** `debug.keystore` está commiteado, así
  que quien tenga acceso al repositorio puede compilar y firmar una actualización con esa clave e
  instalarla encima, sin pasar por el bloqueo. La salvaguarda real es la persona a quien se lo
  cuentas: **cuéntaselo a alguien de confianza.** La app sube mucho el esfuerzo; la otra mitad es
  humana.

## Privacidad

- Salen del teléfono únicamente las consultas DNS que no están bloqueadas, hacia
  CleanBrowsing (o Cloudflare de reserva), como si las hiciera el teléfono sin VPN.
- El guardián lee las pantallas para detectar los casos de arriba. No guarda, no
  registra y no envía nada de lo que ve o escribe. Los campos de contraseña se
  ignoran.
- Lo único que guarda la app: fecha de activación, un contador de bloqueos, tus
  dominios añadidos y tu razón.

## Desarrollo

```
./gradlew :savior:assembleDebug
./gradlew :savior:assembleRelease     # la que publica CI (R8)
./gradlew :savior:testDebugUnitTest   # filtro, paquetes DNS/IP, reglas de texto y de pantalla
```

La lógica sin Android (`DnsFilter`, `DnsPacket`, `IpPacket`, `Resolvers`, `ContentRules`, `Policy`,
`Matcher`, `BackendLogic`) está aislada para poder probarla suelta.

El manifiesto declara en `<queries>` los paquetes y los intents que la app consulta (Android 11+):
sin ellos no se leen los textos de Ajustes ni se reconoce X, el lanzador o el teléfono. No usa
`QUERY_ALL_PACKAGES`.
