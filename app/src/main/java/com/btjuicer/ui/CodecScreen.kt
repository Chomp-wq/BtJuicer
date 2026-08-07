package com.btjuicer.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.btjuicer.adb.AdbState
import com.btjuicer.adb.CodecGrade
import com.btjuicer.adb.CodecStatus
import com.btjuicer.adb.CodecType
import com.btjuicer.adb.LdacQuality
import com.btjuicer.adb.WriteSupport
import com.btjuicer.data.Settings

@Composable
fun CodecScreen(
    settings: Settings,
    adb: AdbState,
    codec: CodecStatus?,
    codecError: String?,
    writeSupport: WriteSupport,
    busy: Boolean,
    onPair: (String, String) -> Unit,
    onConnect: (String) -> Unit,
    onReconnect: (String) -> Unit,
    onDisconnect: () -> Unit,
    onForget: () -> Unit,
    onRefresh: () -> Unit,
    onPollChange: (Boolean) -> Unit,
    onApplyCodec: (Int, LdacQuality?) -> Unit,
    onAutoForceChange: (Boolean) -> Unit,
    onOpenDeveloperOptions: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (adb is AdbState.Connected) {
            item { CodecCard(codec, codecError, onRefresh) }
            item {
                ForceCard(
                    settings = settings,
                    codec = codec,
                    writeSupport = writeSupport,
                    busy = busy,
                    onApply = onApplyCodec,
                    onAutoForceChange = onAutoForceChange,
                )
            }
        }

        item {
            ConnectionCard(
                adb, settings, onPair, onConnect, onReconnect, onDisconnect, onForget,
            )
        }

        if (adb is AdbState.Connected) {
            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Vigilar en segundo plano", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            "Relee el códec cada pocos segundos.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Switch(checked = settings.pollCodec, onCheckedChange = onPollChange)
                }
            }

            if (codec != null && codec.codecType != CodecType.LDAC && codec.supportsLdac) {
                item {
                    Card(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(14.dp)) {
                            Text(
                                "Tus audífonos ofrecen LDAC y no se está usando",
                                style = MaterialTheme.typography.titleSmall,
                                color = warnColor(isSystemInDarkTheme()),
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                "Casi siempre es multipunto activo, o LDAC apagado en la app " +
                                    "del fabricante.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Spacer(Modifier.height(8.dp))
                            Button(onClick = onOpenDeveloperOptions) { Text("Abrir ajustes") }
                        }
                    }
                }
            }
        }

        item { ExplainerCard() }
    }
}

@Composable
private fun CodecCard(codec: CodecStatus?, error: String?, onRefresh: () -> Unit) {
    val dark = isSystemInDarkTheme()
    val color = when (codec?.grade) {
        CodecGrade.EXCELLENT -> okColor(dark)
        CodecGrade.GOOD -> okColor(dark)
        CodecGrade.DEGRADED -> warnColor(dark)
        CodecGrade.BASIC -> badColor(dark)
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Spacer(
                    Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(color),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    "Códec negociado",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Spacer(Modifier.height(8.dp))
            Text(
                text = codec?.headline() ?: "Sin lectura todavía",
                style = MaterialTheme.typography.headlineSmall,
                fontFamily = FontFamily.Monospace,
            )

            codec?.subline()?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = color)
            }

            if (error != null) {
                Spacer(Modifier.height(6.dp))
                Text(error, style = MaterialTheme.typography.bodySmall, color = warnColor(dark))
            }

            Spacer(Modifier.height(12.dp))
            OutlinedButton(onClick = onRefresh) { Text("Leer ahora") }
        }
    }
}

/**
 * Picking the codec, and keeping it.
 *
 * The codec list comes from what the headphones actually advertised whenever the
 * phone told us — offering LDAC to a sink that cannot do it produces a silent
 * fallback to SBC and a user who thinks the app is broken. When the sink has not
 * been read yet, a conservative default list is shown instead.
 */
@Composable
private fun ForceCard(
    settings: Settings,
    codec: CodecStatus?,
    writeSupport: WriteSupport,
    busy: Boolean,
    onApply: (Int, LdacQuality?) -> Unit,
    onAutoForceChange: (Boolean) -> Unit,
) {
    val offered = codec?.selectableCodecs
        ?.filter { it != CodecType.INVALID }
        ?.takeIf { it.isNotEmpty() }
        ?: listOf(CodecType.SBC, CodecType.AAC, CodecType.LDAC)

    // Keyed on the offered list and the saved choice only. Keying on the live
    // codec too would reset the user's selection every time the poll came back.
    var chosen by remember(offered, settings.forcedCodec) {
        mutableStateOf(
            settings.forcedCodec?.takeIf { it in offered }
                ?: codec?.codecType?.takeIf { it in offered }
                ?: offered.last(),
        )
    }
    var quality by remember(settings.forcedLdacRaw) {
        mutableStateOf(
            LdacQuality.fromRaw(settings.forcedLdacRaw ?: -1L)
                ?: codec?.ldacQuality
                ?: LdacQuality.HIGH,
        )
    }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Forzar el códec", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(2.dp))
            Text(
                "Se verifica releyendo: lo que ves es lo que quedó.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Spacer(Modifier.height(14.dp))
            ChipRow(
                options = offered,
                selected = chosen,
                label = { CodecType.label(it) },
                onSelect = { chosen = it },
            )

            if (chosen == CodecType.LDAC) {
                Spacer(Modifier.height(10.dp))
                Text(
                    "Calidad LDAC",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(4.dp))
                ChipRow(
                    options = LdacQuality.entries.toList(),
                    selected = quality,
                    label = { it.bitrate },
                    onSelect = { quality = it },
                )
            }

            if (writeSupport is WriteSupport.No) {
                Spacer(Modifier.height(10.dp))
                Text(
                    writeSupport.reason,
                    style = MaterialTheme.typography.bodySmall,
                    color = badColor(isSystemInDarkTheme()),
                )
            }

            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = { onApply(chosen, quality.takeIf { chosen == CodecType.LDAC }) },
                    enabled = !busy,
                ) { Text("Aplicar") }
                if (busy) {
                    Spacer(Modifier.width(12.dp))
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                }
            }

            Spacer(Modifier.height(6.dp))
            HorizontalDivider()
            Spacer(Modifier.height(6.dp))

            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Volver a aplicar al conectar", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        "Sin esto se deshace en cuanto los audífonos vuelven a la caja.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.width(12.dp))
                Switch(checked = settings.autoForceCodec, onCheckedChange = onAutoForceChange)
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun <T> ChipRow(
    options: List<T>,
    selected: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEach { option ->
            FilterChip(
                selected = option == selected,
                onClick = { onSelect(option) },
                label = { Text(label(option)) },
            )
        }
    }
}

@Composable
private fun ConnectionCard(
    adb: AdbState,
    settings: Settings,
    onPair: (String, String) -> Unit,
    onConnect: (String) -> Unit,
    onReconnect: (String) -> Unit,
    onDisconnect: () -> Unit,
    onForget: () -> Unit,
) {
    var code by remember { mutableStateOf("") }
    var manual by remember { mutableStateOf("") }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Conexión ADB", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))

            when (adb) {
                is AdbState.Working -> Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(10.dp))
                    Text(adb.step, style = MaterialTheme.typography.bodyMedium)
                }

                is AdbState.Connected -> {
                    Text(
                        "Conectado · ${adb.endpoint}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = okColor(isSystemInDarkTheme()),
                    )
                    Spacer(Modifier.height(10.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        // Present even while "connected": a Wi-Fi hiccup leaves a
                        // socket that answers nothing and admits to nothing, and
                        // without this the only way out was to unpair.
                        OutlinedButton(onClick = { onReconnect("") }) { Text("Reconectar") }
                        TextButton(onClick = onDisconnect) { Text("Desconectar") }
                        TextButton(onClick = onForget) { Text("Olvidar") }
                    }
                }

                AdbState.Paired -> {
                    Text(
                        "Emparejado. El puerto cambia en cada reinicio.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(10.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { onConnect(manual) }) { Text("Conectar") }
                        TextButton(onClick = onForget) { Text("Olvidar") }
                    }
                    ManualAddress(manual) { manual = it }
                }

                is AdbState.Error -> {
                    Text(
                        adb.message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = badColor(isSystemInDarkTheme()),
                    )
                    Spacer(Modifier.height(10.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (settings.adbPaired) {
                            Button(onClick = { onConnect(manual) }) { Text("Reintentar") }
                        }
                        TextButton(onClick = onForget) { Text("Empezar de cero") }
                    }
                    if (settings.adbPaired) ManualAddress(manual) { manual = it }
                }

                AdbState.NotPaired -> PairingSteps(
                    code = code,
                    manual = manual,
                    onCodeChange = { code = it.filter(Char::isDigit).take(6) },
                    onManualChange = { manual = it },
                    onPair = { onPair(code, manual) },
                )
            }
        }
    }
}

/**
 * The escape hatch, folded away until asked for.
 *
 * mDNS is right almost always, and when it is wrong it is wrong in a way the
 * user can see and fix in ten seconds — the number is printed on the
 * wireless-debugging screen. Worth offering; not worth putting in front of
 * everyone who will never need it.
 */
@Composable
private fun ManualAddress(value: String, onChange: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }

    if (!open) {
        TextButton(onClick = { open = true }) { Text("Escribir la dirección a mano") }
        return
    }
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text("IP:puerto") },
        placeholder = { Text("192.168.1.40:37103") },
        singleLine = true,
        supportingText = { Text("La que sale en Depuración inalámbrica") },
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun PairingSteps(
    code: String,
    manual: String,
    onCodeChange: (String) -> Unit,
    onManualChange: (String) -> Unit,
    onPair: () -> Unit,
) {
    Column {
        Step(1, "Opciones de desarrollador → activa «Depuración inalámbrica».")
        Step(2, "Toca «Vincular dispositivo con código» y deja esa ventana abierta.")
        Step(3, "Vuelve aquí y escribe el código.")

        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = code,
            onValueChange = onCodeChange,
            label = { Text("Código de vinculación") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(10.dp))
        Button(onClick = onPair, enabled = code.length == 6) { Text("Emparejar") }
        ManualAddress(manual, onManualChange)
    }
}

@Composable
private fun Step(number: Int, text: String) {
    Row(Modifier.padding(vertical = 3.dp)) {
        Text(
            "$number.",
            modifier = Modifier.width(22.dp),
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ExplainerCard() {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp)) {
            Text("Cómo funciona", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(6.dp))
            Text(
                "El sistema sólo le cuenta el códec al usuario shell. BT Juicer se conecta al " +
                    "servidor de depuración del propio teléfono para preguntar — y para fijarlo, " +
                    "arranca ahí un proceso propio. Lo mismo que hace Shizuku, sin segunda app.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
