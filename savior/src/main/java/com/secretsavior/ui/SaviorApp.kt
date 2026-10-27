package com.secretsavior.ui

import android.content.Context
import android.os.Build
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.secretsavior.data.Store
import com.secretsavior.guard.Status
import com.secretsavior.vpn.SaviorVpnService
import kotlinx.coroutines.delay
import java.text.DateFormat
import java.util.Date

/** Lo que la pantalla puede pedirle a la actividad. Nótese lo que no hay: ninguna acción de apagar. */
interface Actions {
    fun enableVpn()
    fun openAccessibility()
    fun openAppInfo()
    fun enableAdmin()
    fun openNetworkSettings()
    fun exemptBattery()
    fun openAutostart()
    fun commit()
}

private data class Snapshot(
    val locked: Boolean,
    val vpn: Boolean,
    val guard: Boolean,
    val admin: Boolean,
    val dnsStrict: Boolean,
    val battery: Boolean,
    /** Xiaomi/Redmi/POCO: el autoencendido de la app se vio activado. En otras marcas no se pide. */
    val autostart: Boolean,
    val days: Long,
    val since: Long,
    val blocked: Int,
    val dns: SaviorVpnService.Companion.DnsHealth?,
) {
    val ready get() = vpn && guard && admin && !dnsStrict && autostart
}

private fun read(c: Context) = Snapshot(
    locked = Store.isLocked(c),
    vpn = Status.isVpnRunning(),
    guard = Status.isGuardEnabled(c),
    admin = Status.isAdminActive(c),
    dnsStrict = Status.isPrivateDnsStrict(c),
    battery = Status.isBatteryExempt(c),
    autostart = !isXiaomiFamily() || Store.autostartSeen(c),
    days = Store.daysLocked(c),
    since = Store.lockedAt(c),
    blocked = Store.blockedCount(c),
    dns = SaviorVpnService.dnsHealth,
)

private fun isXiaomiFamily() = Build.MANUFACTURER.lowercase() in setOf("xiaomi", "redmi", "poco")

@Composable
fun SaviorApp(actions: Actions) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var snap by remember { mutableStateOf(read(context)) }
    // Sólo mientras la pantalla se ve: el estado cambia al volver de Ajustes.
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                snap = read(context)
                delay(1000)
            }
        }
    }
    Surface(Modifier.fillMaxSize()) {
        Box(Modifier.safeDrawingPadding()) {
            if (snap.locked) LockedScreen(snap, actions) else SetupScreen(snap, actions)
        }
    }
}

// --- Antes de activar ---------------------------------------------------------------

private const val PHRASE = "ME COMPROMETO"

@Composable
private fun SetupScreen(s: Snapshot, a: Actions) {
    var phrase by rememberSaveable { mutableStateOf("") }
    var understood by rememberSaveable { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    val canLock = s.ready && understood && phrase.trim().equals(PHRASE, ignoreCase = true)

    Column(
        Modifier.verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("Secret Savior", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
        Text(
            "Un bloqueo de pornografía que, una vez activado, no se puede apagar desde el " +
                "teléfono. Para quien ya decidió dejarlo y sabe que la fuerza de voluntad a las " +
                "tres de la madrugada no es fiable: la decisión se toma ahora, con la cabeza fría.",
            style = MaterialTheme.typography.bodyLarge,
        )

        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Lo que tienes que saber", fontWeight = FontWeight.Bold)
                Text("• No habrá botón de desactivar. Ni con contraseña, ni con espera, ni para quien la escribió.")
                Text("• Para quitarla habría que restablecer el teléfono de fábrica, arrancar en modo seguro o usar un ordenador (ADB). Es a propósito: hace falta querer de verdad, no un impulso.")
                Text("• Ningún filtro es perfecto. Esto sube mucho el esfuerzo, no lo hace imposible. Cuéntaselo a alguien de confianza: es la mitad del método.")
                Text("• Nada de lo que escribes o ves sale del teléfono. Sólo las consultas DNS viajan, a un resolutor con filtro familiar.")
            }
        }

        Text("Cuatro permisos", style = MaterialTheme.typography.titleLarge)

        Step(
            "1. Filtro de sitios (VPN local)", s.vpn,
            "Intercepta únicamente las consultas DNS: los sitios para adultos no llegan a resolver. " +
                "No pasa tu tráfico por ningún servidor.",
        ) { Button(onClick = a::enableVpn) { Text("Permitir y arrancar") } }

        Step(
            "2. Guardián (Accesibilidad)", s.guard,
            "Cierra las pantallas de Ajustes desde las que se podría apagar todo, y el texto " +
                "explícito. Si Android 13+ lo muestra en gris porque instalaste el APK a mano: " +
                "abre «Información de la app», menú ⋮ y «Permitir ajustes restringidos».",
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = a::openAccessibility) { Text("Abrir accesibilidad") }
                OutlinedButton(onClick = a::openAppInfo) { Text("Info de la app") }
            }
        }

        Step(
            "3. Protección contra desinstalación", s.admin,
            "Con la app como administradora, Android se niega a desinstalarla.",
        ) { Button(onClick = a::enableAdmin) { Text("Activar administrador") } }

        Step(
            "4. Sin DNS privado estricto", !s.dnsStrict,
            if (s.dnsStrict) {
                "Tienes un DNS privado con nombre de host: cifra las consultas y se salta el filtro. " +
                    "Ponlo en «Automático» o «Desactivado» (Ajustes → Red → DNS privado)."
            } else {
                "Todo en orden: el DNS privado no esquiva el filtro."
            },
        ) { if (s.dnsStrict) Button(onClick = a::openNetworkSettings) { Text("Abrir ajustes de red") } }

        if (isXiaomiFamily()) {
            Step(
                "5. Autoencendido (Xiaomi)", s.autostart,
                "Abre la pantalla y comprueba que Secret Savior está activado: la app lo detecta " +
                    "sola (necesita el paso 2). Una vez bloqueado, esa pantalla se cierra para " +
                    "siempre, así que cambia antes el autoencendido de tus otras apps.",
            ) { Button(onClick = a::openAutostart) { Text("Abrir autoencendido") } }
        }

        if (!s.battery) {
            Step(
                "Opcional: que no lo duerman", false,
                "Algunos fabricantes matan los servicios para ahorrar batería. Excluir la app lo evita.",
            ) { OutlinedButton(onClick = a::exemptBattery) { Text("Excluir de ahorro") } }
        }

        Card {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Activar para siempre", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                OutlinedTextField(
                    value = phrase,
                    onValueChange = { phrase = it },
                    label = { Text("Escribe: $PHRASE") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = understood, onCheckedChange = { understood = it })
                    Text("Entiendo que no podré desactivarlo desde el teléfono.", Modifier.weight(1f))
                }
                Button(onClick = { confirm = true }, enabled = canLock, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Lock, null)
                    Spacer(Modifier.size(8.dp))
                    Text("Activar y bloquear")
                }
                if (!s.ready) {
                    Text(
                        "Faltan permisos por conceder arriba.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
        }
    }

    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("¿Seguro?") },
            text = {
                Text(
                    "Después de esto no hay marcha atrás desde la app. Si ahora mismo dudas, " +
                        "espera: nada se pierde por activarlo mañana.",
                )
            },
            confirmButton = {
                Button(onClick = { confirm = false; a.commit() }) { Text("Sí, activar") }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Todavía no") } },
        )
    }
}

@Composable
private fun Step(title: String, done: Boolean, text: String, action: @Composable () -> Unit) {
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(
                    if (done) Icons.Filled.CheckCircle else Icons.Filled.Warning,
                    contentDescription = if (done) "Hecho" else "Pendiente",
                    tint = if (done) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                )
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            }
            Text(text, style = MaterialTheme.typography.bodyMedium)
            if (!done) action()
        }
    }
}

// --- Con el bloqueo activo ----------------------------------------------------------

@Composable
private fun LockedScreen(s: Snapshot, a: Actions) {
    val context = LocalContext.current
    val isXiaomi = isXiaomiFamily()
    var urge by remember { mutableStateOf(false) }
    var reason by remember { mutableStateOf(Store.reason(context)) }
    var domain by remember { mutableStateOf("") }
    var domainMsg by remember { mutableStateOf<String?>(null) }

    Column(
        Modifier.verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
            Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Protección activa", style = MaterialTheme.typography.titleMedium)
                Text("${s.days}", fontSize = 72.sp, fontWeight = FontWeight.Bold)
                Text(if (s.days == 1L) "día" else "días", style = MaterialTheme.typography.titleLarge)
                if (s.since > 0) {
                    Text(
                        "desde el ${DateFormat.getDateInstance().format(Date(s.since))}",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }

        Button(onClick = { urge = true }, modifier = Modifier.fillMaxWidth().height(56.dp)) {
            Text("Tengo ganas ahora mismo", fontSize = 18.sp)
        }

        Card {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Estado", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                StatusRow("Filtro de sitios", s.vpn, a::enableVpn)
                StatusRow("Guardián", s.guard, a::openAccessibility)
                StatusRow("Anti-desinstalación", s.admin, a::enableAdmin)
                if (s.dnsStrict) StatusRow("DNS privado estricto (esquiva el filtro)", false, a::openNetworkSettings)
                Text("${s.blocked} sitios bloqueados hasta hoy", style = MaterialTheme.typography.bodySmall)
                s.dns?.let { dns ->
                    // Menos de ~80 ms no se nota; por encima de ~250 ms el resolutor está lejos o la red va mal.
                    val slow = dns.averageMs > 250
                    Text(
                        when {
                            dns.broken ->
                                "El DNS no responde (${dns.recentFailed} de las últimas ${dns.recentTotal} consultas). " +
                                    "Si pasa sólo en una red, esa red bloquea DNS externo (hoteles, trabajo, colegio); " +
                                    "si pasa en todas, comprueba que Secret Savior tenga acceso a datos y Wi-Fi en " +
                                    "Seguridad → Uso de datos."
                            slow -> "DNS: ${dns.averageMs} ms de media (lento: puede ser la red)"
                            else -> "DNS: ${dns.averageMs} ms de media"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = if (dns.broken || slow) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        Card {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Siempre activo", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(
                    "El filtro sigue aunque cierres la app: va en primer plano con una notificación fija. " +
                        "Para que el sistema no lo duerma:",
                    style = MaterialTheme.typography.bodySmall,
                )
                StatusRow("Sin ahorro de batería", s.battery, a::exemptBattery)
                if (isXiaomi) {
                    Text(
                        "Xiaomi / Redmi / POCO: el autoencendido de esta app queda fijado, y su pantalla " +
                            "de ajustes se cierra mientras dure el bloqueo.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Text(
                        "Y en Recientes, mantén pulsada la tarjeta de la app y toca el candado: así " +
                            "«Limpiar» no la cierra.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }

        Card {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Mi razón", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text("La verás cuando pulses «Tengo ganas». Escríbela tú, con tus palabras.", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(
                    value = reason,
                    onValueChange = { reason = it.take(600); Store.setReason(context, reason) },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 2,
                )
            }
        }

        Card {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Bloquear otro sitio", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text("Se pueden añadir sitios, nunca quitarlos.", style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = domain,
                        onValueChange = { domain = it; domainMsg = null },
                        placeholder = { Text("ejemplo.com") },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                    Button(onClick = {
                        domainMsg = if (Store.addDomain(context, domain)) {
                            domain = ""
                            "Añadido."
                        } else {
                            "Eso no parece un dominio."
                        }
                    }) { Text("Añadir") }
                }
                domainMsg?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
        }

        Text(
            "No hay botón para desactivar esta protección. Es a propósito.",
            style = MaterialTheme.typography.bodySmall,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }

    if (urge) UrgeDialog(reason) { urge = false }
}

@Composable
private fun StatusRow(label: String, ok: Boolean, repair: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(
            if (ok) Icons.Filled.CheckCircle else Icons.Filled.Warning,
            contentDescription = if (ok) "Activo" else "Caído",
            tint = if (ok) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
        )
        Spacer(Modifier.size(8.dp))
        Text(label, Modifier.weight(1f))
        // Reparar es volver a conceder lo que se cayó; nunca apagar.
        if (!ok) TextButton(onClick = repair) { Text("Reparar") }
    }
}

/** Respiración 4-7-8, la razón propia y una lista corta de cosas que cambian de sitio el cuerpo. */
@Composable
private fun UrgeDialog(reason: String, onClose: () -> Unit) {
    var label by remember { mutableStateOf("Inhala") }
    var count by remember { mutableStateOf(4) }

    LaunchedEffect(Unit) {
        while (true) {
            for ((name, seconds) in listOf("Inhala" to 4, "Sostén" to 7, "Exhala" to 8)) {
                for (t in seconds downTo 1) {
                    label = name
                    count = t
                    delay(1000)
                }
            }
        }
    }
    val size by animateDpAsState(
        targetValue = if (label == "Exhala") 80.dp else 150.dp,
        animationSpec = tween(if (label == "Sostén") 300 else if (label == "Exhala") 8000 else 4000),
        label = "respiración",
    )

    AlertDialog(
        onDismissRequest = onClose,
        title = { Text("Esto pasa") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Una ola de ganas dura unos minutos y baja sola. No tienes que ganarle: sólo esperarla.")
                Box(Modifier.height(160.dp), contentAlignment = Alignment.Center) {
                    Column(
                        Modifier.size(size).clip(CircleShape).background(MaterialTheme.colorScheme.primaryContainer),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                    ) {
                        Text(label, fontWeight = FontWeight.Bold)
                        Text("$count", fontSize = 28.sp)
                    }
                }
                if (reason.isNotBlank()) {
                    Card {
                        Column(Modifier.padding(12.dp)) {
                            Text("Tu razón", fontWeight = FontWeight.Bold)
                            Text(reason)
                        }
                    }
                }
                Text(
                    "Mientras tanto: levántate, sal de la habitación, deja el móvil lejos, bebe un vaso de " +
                        "agua, haz veinte flexiones o llama a alguien. Cambiar de sitio al cuerpo cambia el " +
                        "pensamiento.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        },
        confirmButton = { Button(onClick = onClose) { Text("Ya pasó") } },
    )
}
