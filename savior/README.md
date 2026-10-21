# Secret Savior

Bloqueo de pornografía para Android pensado para quien quiere dejarlo: **una vez
activado no se puede desactivar desde el teléfono.** La decisión se toma una vez,
con la cabeza fría, y deja de ser una decisión que haya que volver a ganar cada
noche.

Módulo `:savior` de este repositorio (`com.secretsavior`). Sin servidores propios,
sin cuentas, sin anuncios, sin telemetría.

## Cómo funciona

Cuatro capas, cada una cubre un hueco de la anterior.

| Capa | Qué hace |
|---|---|
| **Filtro DNS** (`VpnService` local) | Captura sólo las consultas DNS del teléfono. Los dominios de la lista local (palabras clave, TLD `.xxx/.porn/.sex/.adult`, ~70 sitios y CDN, redes de anuncios para adultos) reciben `0.0.0.0`. El resto se reenvía a **CleanBrowsing Adult Filter** (185.228.168.10), que bloquea pornografía y contenido explícito y fuerza búsqueda segura en Google y Bing (deja pasar sitios mixtos como Reddit: ahí actúa el guardián); Cloudflare for Families (1.1.1.3) queda de reserva. Se usan también sus direcciones IPv6. Los proveedores de DNS cifrado (DoH) también se bloquean para que el navegador no se salte el filtro. No pasa tu tráfico por ningún servidor. |
| **Guardián** (`AccessibilityService`) | Manda al inicio cualquier pantalla de Ajustes/instalador/VPN que nombre a la app (ficha, desinstalar, administradores, accesibilidad, «Desconectar» VPN) y el campo de DNS privado. Cierra el navegador si apunta a un sitio bloqueado, y **falla cerrado**: si el filtro está caído, los navegadores no funcionan hasta repararlo. Cierra el texto explícito que se escribe, sólo en navegadores, buscadores (Google, YouTube), Telegram y Reddit: WhatsApp, SMS y el resto de chats no se vigilan, para no limitar la comunicación. |
| **Administrador del dispositivo** | Mientras la app sea administradora, Android se niega a desinstalarla. Quitarla de la lista es la pantalla que el guardián cierra. |
| **Siempre activo** | El filtro va como servicio en primer plano con notificación fija, así que cerrar la app no lo detiene. Si el sistema aun así lo mata (Xiaomi al «Limpiar» Recientes), una alarma lo vuelve a levantar en segundos; la pantalla principal guía el autoinicio y la exclusión de ahorro de batería. |
| **Vigilante** | Cada 10 s, al arrancar y al caerse el filtro, levanta lo que falte. Si otra VPN le quita el permiso o se retira un permiso, trae la app al frente para repararlo. |

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
- **El guardián no frena otras apps.** Descarta al instante los eventos de las apps
  que no vigila, sin pedirles nada. En navegadores pide la barra de direcciones por su
  id (una consulta) y en Ajustes revisa la pantalla como mucho dos veces por segundo.

Lo que no depende de la app: la primera visita a cada dominio espera la respuesta de
CleanBrowsing, que según dónde estés puede estar más lejos que el DNS de tu
operador. Android guarda las respuestas en caché, así que sólo se nota la primera vez.

## Instalar

CI publica `Secret-Savior.apk` en la release `latest`. En Android 13+, si lo
instalas a mano: **Información de la app → ⋮ → Permitir ajustes restringidos**
antes de activar la accesibilidad. La app te guía en cuatro pasos y exige escribir
una frase de compromiso antes de activar.

## Lo que no hace (honestidad)

Ningún bloqueo en el propio teléfono es imposible de quitar, y esta app no finge
lo contrario:

- **Restablecer de fábrica** lo quita, como cualquier otra app.
- **Modo seguro** (mantener «Apagar» en el menú de apagado): en él no corre
  ninguna app de terceros, tampoco el guardián, y desde Ajustes se puede quitar el
  administrador y desinstalar. Es el punto débil más fácil y una app normal no
  puede cerrarlo; sólo una app «propietaria del dispositivo» podría (ver abajo).
- Con un ordenador y **ADB** se puede apagar el guardián
  (`settings put secure enabled_accessibility_services …`) y después quitar el
  administrador desde Ajustes. `adb uninstall` a secas falla mientras sea
  administradora.
- Crear **otro usuario o un invitado** en el teléfono da un espacio sin filtro.
- Otro navegador/app con **DNS-sobre-HTTPS por IP fija** o una **VPN** de terceros
  evita el filtro DNS. Una VPN ajena le quita el puesto a la nuestra y los
  navegadores se cierran hasta recuperarlo; una app con DoH propio por IP no se
  detecta.
- El filtro de URL del guardián sólo entiende las barras de direcciones de los
  navegadores conocidos; la lista de palabras es amplia pero no perfecta (puede
  bloquear algo inocente y dejar pasar algo).
- No filtra el contenido de imágenes o vídeo dentro de apps (redes sociales,
  etc.): bloquea sitios y búsquedas, no lo que una app decida mostrar.

Una versión más dura existe: si la app fuera **propietaria del dispositivo**
(`adb shell dpm set-device-owner`, sólo en un teléfono sin cuentas añadidas)
podría prohibir el modo seguro, el restablecimiento desde Ajustes, otros usuarios
y otras VPN. Esta versión todavía no lo hace.

Por eso el método real es **combinarlo con una persona**: cuéntaselo a alguien de
confianza. La app sube mucho el esfuerzo; la otra mitad es humana.

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
./gradlew :savior:testDebugUnitTest   # filtro, paquetes DNS/IP y reglas de texto
```

La lógica sin Android (`DnsFilter`, `DnsPacket`, `IpPacket`, `ContentRules`) está
aislada para poder probarla suelta.
