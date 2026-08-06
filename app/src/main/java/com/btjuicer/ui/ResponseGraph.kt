package com.btjuicer.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import com.btjuicer.audio.Curve
import com.btjuicer.audio.Filter
import kotlin.math.ln

/**
 * The curve you are actually getting.
 *
 * Not a decoration: with ten overlapping bells or an imported list of thirty
 * biquads, the only honest way to know what the equaliser does is to plot its
 * combined magnitude response. Sliders lie; this does not.
 */
@Composable
fun ResponseGraph(
    filters: List<Filter>,
    modifier: Modifier = Modifier,
    rangeDb: Float = 15f,
) {
    val dark = isSystemInDarkTheme()
    val gridColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.20f)
    val zeroColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f)
    val lineColor = MaterialTheme.colorScheme.primary
    val fillColor = lineColor.copy(alpha = if (dark) 0.18f else 0.12f)

    val points = Curve.forPlot(filters, resolution = 200)

    Canvas(
        modifier = modifier
            .fillMaxWidth()
            .height(160.dp),
    ) {
        val w = size.width
        val h = size.height
        val logFrom = ln(20.0)
        val logTo = ln(20_000.0)

        fun xOf(hz: Float): Float =
            ((ln(hz.toDouble()) - logFrom) / (logTo - logFrom)).toFloat() * w

        fun yOf(db: Float): Float = h / 2f - (db / rangeDb) * (h / 2f)

        // Decade and octave grid, so the eye can place a frequency.
        listOf(20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000).forEach { hz ->
            val x = xOf(hz.toFloat())
            drawLine(gridColor, Offset(x, 0f), Offset(x, h), strokeWidth = 1f)
        }
        listOf(-12f, -6f, 6f, 12f).forEach { db ->
            val y = yOf(db)
            drawLine(gridColor, Offset(0f, y), Offset(w, y), strokeWidth = 1f)
        }
        drawLine(zeroColor, Offset(0f, yOf(0f)), Offset(w, yOf(0f)), strokeWidth = 2f)

        if (points.isEmpty()) return@Canvas

        val line = Path()
        val area = Path()
        points.forEachIndexed { index, (hz, db) ->
            val x = xOf(hz)
            val y = yOf(db.coerceIn(-rangeDb, rangeDb))
            if (index == 0) {
                line.moveTo(x, y)
                area.moveTo(x, yOf(0f))
                area.lineTo(x, y)
            } else {
                line.lineTo(x, y)
                area.lineTo(x, y)
            }
        }
        area.lineTo(xOf(points.last().first), yOf(0f))
        area.close()

        drawPath(area, fillColor)
        drawPath(line, lineColor, style = Stroke(width = 3f))
    }
}

/** Colour for a dB readout: green when boosting, amber when cutting hard. */
fun gainColor(db: Float, dark: Boolean): Color = when {
    db > 0.05f -> okColor(dark)
    db < -0.05f -> infoColor(dark)
    else -> Color.Unspecified
}
