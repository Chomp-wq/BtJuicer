package com.btjuicer.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.btjuicer.audio.Backend
import com.btjuicer.audio.Curve
import com.btjuicer.audio.EngineState
import com.btjuicer.audio.EqConfig
import com.btjuicer.audio.EqMode
import com.btjuicer.audio.Filter
import com.btjuicer.audio.FilterType
import com.btjuicer.audio.MAX_GAIN_DB
import com.btjuicer.audio.MAX_PREAMP_DB
import com.btjuicer.audio.MIN_GAIN_DB
import com.btjuicer.audio.MIN_PREAMP_DB
import com.btjuicer.audio.MbcMode
import com.btjuicer.audio.Presets
import com.btjuicer.audio.formatHz
import com.btjuicer.data.Profile
import com.btjuicer.data.Settings
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.pow

private val ScreenPadding = PaddingValues(16.dp)

@Composable
fun EqScreen(
    settings: Settings,
    engine: EngineState,
    profiles: List<Profile>,
    connectedDeviceName: String,
    viewModel: MainViewModel,
    onPickFile: () -> Unit,
) {
    val eq = settings.eq
    val filters = remember(eq) { eq.activeFilters() }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = ScreenPadding,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item { PowerCard(eq, engine, viewModel::setEqEnabled) }

        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    ResponseGraph(filters)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "20 Hz — 20 kHz · líneas cada 6 dB. Esta es la respuesta combinada real, " +
                            "no la posición de los mandos.",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (eq.sourceLabel.isNotEmpty()) {
                        Text(
                            eq.sourceLabel,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                }
            }
        }

        item { ModeChips(eq.mode, viewModel::setMode) }

        if (eq.mode == EqMode.SIMPLE) {
            item {
                Column {
                    Text("Presets", style = MaterialTheme.typography.titleSmall)
                    PresetChips(eq.presetName, viewModel::applyPreset)
                    Presets.byLabel(eq.presetName)?.let {
                        Text(
                            it.note,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Bandas", style = MaterialTheme.typography.titleSmall)
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = viewModel::resetFlat) { Text("Aplanar") }
                }
            }

            items(Curve.OCTAVE.size) { index ->
                BandSlider(
                    hz = Curve.OCTAVE[index],
                    targetDb = eq.bandsDb.getOrElse(index) { 0f },
                    enabled = eq.enabled,
                    onChange = { viewModel.setBand(index, it) },
                )
            }

            item {
                Text(
                    "Cada mando es un objetivo, no una ganancia: la app resuelve los filtros para " +
                        "que +6 dB en 125 Hz sean exactamente +6 dB ahí. Un ecualizador gráfico " +
                        "normal se pasaría un par de dB por el solape entre bandas.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Filtros (${eq.filters.size})",
                        style = MaterialTheme.typography.titleSmall,
                    )
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = viewModel::addFilter) { Text("Añadir") }
                }
            }

            items(eq.filters.size) { index ->
                FilterRow(
                    filter = eq.filters[index],
                    enabled = eq.enabled,
                    onChange = { viewModel.updateFilter(index, it) },
                    onRemove = { viewModel.removeFilter(index) },
                )
            }

            if (eq.filters.isEmpty()) {
                item {
                    Text(
                        "Sin filtros. Añade uno a mano o importa un perfil de AutoEq abajo.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        item { HorizontalDivider(Modifier.padding(vertical = 4.dp)) }

        item { ImportCard(onImport = viewModel::importAutoEq, onPickFile = onPickFile) }

        item { HorizontalDivider(Modifier.padding(vertical = 4.dp)) }

        item { GainCard(eq, viewModel) }

        item { MbcCard(eq.mbc, viewModel::setMbc) }

        item { HorizontalDivider(Modifier.padding(vertical = 4.dp)) }

        item {
            ProfilesCard(
                profiles = profiles,
                activeId = settings.activeProfileId,
                autoProfile = settings.autoProfile,
                connectedDeviceName = connectedDeviceName,
                onSave = viewModel::saveProfile,
                onApply = viewModel::applyProfile,
                onDelete = viewModel::deleteProfile,
                onAutoChange = viewModel::setAutoProfile,
            )
        }
    }
}

// ------------------------------------------------------------------- pieces

@Composable
private fun PowerCard(eq: EqConfig, engine: EngineState, onEnabledChange: (Boolean) -> Unit) {
    val dark = isSystemInDarkTheme()

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Ecualizador", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Actúa sobre toda la salida del teléfono, incluidas las apps de streaming.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.width(12.dp))
                Switch(checked = eq.enabled, onCheckedChange = onEnabledChange)
            }

            Spacer(Modifier.height(8.dp))
            when (engine) {
                is EngineState.Active -> Text(
                    text = buildString {
                        append(
                            when (engine.backend) {
                                Backend.DYNAMICS -> "Activo · ${engine.bandCount} bandas"
                                Backend.LEGACY -> "Modo compatible · ${engine.bandCount} bandas " +
                                    "del sistema"
                            },
                        )
                        if (engine.mbcActive) append(" · compresor activo")
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = okColor(dark),
                )

                is EngineState.Failed -> Text(
                    engine.reason,
                    style = MaterialTheme.typography.bodySmall,
                    color = badColor(dark),
                )

                EngineState.Off -> Text(
                    "Apagado.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ModeChips(mode: EqMode, onChange: (EqMode) -> Unit) {
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        EqMode.entries.forEach { entry ->
            FilterChip(
                selected = mode == entry,
                onClick = { onChange(entry) },
                label = { Text(entry.label) },
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PresetChips(selected: String, onPreset: (com.btjuicer.audio.Preset) -> Unit) {
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Presets.ALL.forEach { preset ->
            FilterChip(
                selected = preset.label == selected,
                onClick = { onPreset(preset) },
                label = { Text(preset.label) },
            )
        }
        if (selected == Presets.CUSTOM_LABEL) {
            FilterChip(selected = true, onClick = {}, label = { Text(Presets.CUSTOM_LABEL) })
        }
    }
}

@Composable
private fun BandSlider(hz: Int, targetDb: Float, enabled: Boolean, onChange: (Float) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = if (hz >= 1_000) "${hz / 1000}k" else "$hz",
            modifier = Modifier.width(40.dp),
            style = MaterialTheme.typography.labelMedium,
            fontFamily = FontFamily.Monospace,
            textAlign = TextAlign.End,
        )
        Slider(
            value = targetDb,
            onValueChange = onChange,
            modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
            enabled = enabled,
            valueRange = MIN_GAIN_DB..MAX_GAIN_DB,
            steps = 47,
        )
        Text(
            text = "%+.1f".format(targetDb),
            modifier = Modifier.width(44.dp),
            style = MaterialTheme.typography.labelMedium,
            fontFamily = FontFamily.Monospace,
            textAlign = TextAlign.End,
        )
    }
}

/** Frequency moves on a log axis; a linear slider would waste 90% of its travel above 2 kHz. */
private fun hzToSlider(hz: Float): Float =
    ((ln(hz.coerceIn(20f, 20_000f).toDouble()) - ln(20.0)) / (ln(20_000.0) - ln(20.0))).toFloat()

private fun sliderToHz(v: Float): Float =
    exp(ln(20.0) + (ln(20_000.0) - ln(20.0)) * v).toFloat()

@Composable
private fun FilterRow(
    filter: Filter,
    enabled: Boolean,
    onChange: (Filter) -> Unit,
    onRemove: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(
                    checked = filter.enabled,
                    onCheckedChange = { onChange(filter.copy(enabled = it)) },
                    enabled = enabled,
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    filter.describe(),
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                )
                TextButton(onClick = { expanded = !expanded }) {
                    Text(if (expanded) "Cerrar" else "Editar")
                }
                IconButton(onClick = onRemove) {
                    Icon(Icons.Filled.Delete, contentDescription = "Eliminar filtro")
                }
            }

            if (!expanded) return@Column

            Spacer(Modifier.height(4.dp))
            FilterTypeChips(filter.type) { onChange(filter.copy(type = it)) }

            LabelledSlider(
                label = "Frecuencia",
                value = hzToSlider(filter.freqHz),
                readout = formatHz(filter.freqHz),
                enabled = enabled,
                onChange = { onChange(filter.copy(freqHz = sliderToHz(it))) },
            )

            if (filter.type.usesGain) {
                LabelledSlider(
                    label = "Ganancia",
                    value = filter.gainDb,
                    range = -24f..24f,
                    steps = 95,
                    readout = "%+.1f dB".format(filter.gainDb),
                    enabled = enabled,
                    onChange = { onChange(filter.copy(gainDb = it)) },
                )
            }

            LabelledSlider(
                label = "Q (ancho)",
                // Q also moves logarithmically: the useful range is 0.2 to 10.
                value = (ln(filter.q.coerceIn(0.2f, 10f).toDouble()) / ln(10.0)).toFloat(),
                range = -0.7f..1f,
                readout = "%.2f".format(filter.q),
                enabled = enabled,
                onChange = { onChange(filter.copy(q = 10f.pow(it))) },
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FilterTypeChips(type: FilterType, onChange: (FilterType) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        FilterType.entries.forEach { entry ->
            FilterChip(
                selected = entry == type,
                onClick = { onChange(entry) },
                label = { Text(entry.label, style = MaterialTheme.typography.labelSmall) },
            )
        }
    }
}

@Composable
private fun LabelledSlider(
    label: String,
    value: Float,
    readout: String,
    enabled: Boolean,
    onChange: (Float) -> Unit,
    range: ClosedFloatingPointRange<Float> = 0f..1f,
    steps: Int = 0,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            label,
            modifier = Modifier.width(88.dp),
            style = MaterialTheme.typography.labelSmall,
        )
        Slider(
            value = value.coerceIn(range.start, range.endInclusive),
            onValueChange = onChange,
            modifier = Modifier.weight(1f).padding(horizontal = 6.dp),
            enabled = enabled,
            valueRange = range,
            steps = steps,
        )
        Text(
            readout,
            modifier = Modifier.width(72.dp),
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            textAlign = TextAlign.End,
        )
    }
}

@Composable
private fun ImportCard(onImport: (String) -> Unit, onPickFile: () -> Unit) {
    var text by remember { mutableStateOf("") }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp)) {
            Text("Importar de AutoEq", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(4.dp))
            Text(
                "AutoEq publica correcciones medidas para miles de audífonos concretos. Es la " +
                    "diferencia entre mover mandos a ojo y aplicar una corrección derivada de una " +
                    "medición de tu modelo exacto — con diferencia, la mayor mejora posible en un " +
                    "ecualizador.\n\nBusca tu modelo en el proyecto AutoEq, abre su " +
                    "«ParametricEQ.txt» o «GraphicEQ.txt» y pega el contenido aquí, o elige el " +
                    "archivo.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(10.dp))
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                label = { Text("Pega aquí el perfil") },
                modifier = Modifier.fillMaxWidth().height(140.dp),
                textStyle = MaterialTheme.typography.bodySmall,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text),
            )
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { onImport(text) }, enabled = text.isNotBlank()) {
                    Text("Importar")
                }
                OutlinedButton(onClick = onPickFile) { Text("Elegir archivo") }
            }
        }
    }
}

@Composable
private fun GainCard(eq: EqConfig, viewModel: MainViewModel) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Ganancia previa", style = MaterialTheme.typography.titleSmall)
                Spacer(Modifier.weight(1f))
                TextButton(onClick = viewModel::autoPreamp) { Text("Automática") }
            }
            Slider(
                value = eq.preampDb.coerceIn(MIN_PREAMP_DB, MAX_PREAMP_DB),
                onValueChange = viewModel::setPreamp,
                enabled = eq.enabled,
                valueRange = MIN_PREAMP_DB..MAX_PREAMP_DB,
                steps = 51,
            )
            Text(
                "%+.1f dB".format(eq.preampDb),
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
            )
            Text(
                "Bajarla compensa lo que suben las bandas. Sin eso, activar el ecualizador sólo " +
                    "sube el volumen y todo parece mejor sin serlo.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Spacer(Modifier.height(10.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Limitador", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        "Impide que los picos saturen. Déjalo activado.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.width(12.dp))
                Switch(
                    checked = eq.limiterEnabled,
                    onCheckedChange = viewModel::setLimiter,
                    enabled = eq.enabled,
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MbcCard(mode: MbcMode, onChange: (MbcMode) -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp)) {
            Text("Compresor multibanda", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(6.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                MbcMode.entries.forEach { entry ->
                    FilterChip(
                        selected = entry == mode,
                        onClick = { onChange(entry) },
                        label = { Text(entry.label) },
                    )
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(
                mode.note,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ProfilesCard(
    profiles: List<Profile>,
    activeId: String?,
    autoProfile: Boolean,
    connectedDeviceName: String,
    onSave: (String, Boolean) -> Unit,
    onApply: (String) -> Unit,
    onDelete: (String) -> Unit,
    onAutoChange: (Boolean) -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var bind by remember { mutableStateOf(true) }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp)) {
            Text("Perfiles", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(4.dp))
            Text(
                "Una corrección sólo es correcta para el audífono sobre el que se midió. Ata cada " +
                    "curva a sus audífonos y la app la pondrá sola al conectarlos.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Spacer(Modifier.height(10.dp))
            profiles.forEach { profile ->
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            profile.name,
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = if (profile.id == activeId) FontWeight.SemiBold else FontWeight.Normal,
                        )
                        val subtitle = buildString {
                            if (profile.deviceAddress != null) {
                                append(profile.deviceName.ifEmpty { profile.deviceAddress })
                            } else {
                                append("Sin dispositivo")
                            }
                            if (profile.id == activeId) append(" · en uso")
                        }
                        Text(
                            subtitle,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    TextButton(onClick = { onApply(profile.id) }) { Text("Usar") }
                    IconButton(onClick = { onDelete(profile.id) }) {
                        Icon(Icons.Filled.Delete, contentDescription = "Eliminar perfil")
                    }
                }
            }
            if (profiles.isEmpty()) {
                Text(
                    "Todavía no hay perfiles guardados.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Spacer(Modifier.height(10.dp))
            HorizontalDivider()
            Spacer(Modifier.height(10.dp))

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Nombre del perfil") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(
                    checked = bind && connectedDeviceName.isNotEmpty(),
                    onCheckedChange = { bind = it },
                    enabled = connectedDeviceName.isNotEmpty(),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    if (connectedDeviceName.isNotEmpty()) {
                        "Asociar a $connectedDeviceName"
                    } else {
                        "Conecta unos audífonos para poder asociarlo"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = {
                    onSave(name, bind && connectedDeviceName.isNotEmpty())
                    name = ""
                },
                enabled = name.isNotBlank(),
            ) {
                Text("Guardar curva actual")
            }

            Spacer(Modifier.height(10.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Cambiar solo al conectar", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        "Aplica el perfil asociado en cuanto se conectan sus audífonos.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.width(12.dp))
                Switch(checked = autoProfile, onCheckedChange = onAutoChange)
            }
        }
    }
}
