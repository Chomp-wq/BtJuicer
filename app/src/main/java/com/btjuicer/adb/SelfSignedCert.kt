package com.btjuicer.adb

import java.math.BigInteger
import java.security.KeyPair
import java.security.MessageDigest
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Builds a self-signed X.509 certificate around an existing key pair.
 *
 * Android ships no public API for this. The usual answers are BouncyCastle (a
 * megabyte of crypto library for one certificate) or the `sun.security.x509`
 * classes, which do not exist on Android and have to be side-loaded from a
 * backport whose `X509CertInfo.set("subject", …)` string-keyed API changed
 * shape across JDK versions. A certificate is a few hundred bytes of DER, so it
 * is written out directly here — no dependency, and the encoder is plain JVM
 * code that can be run and checked outside of Android.
 *
 * The certificate exists only so the TLS handshake with the phone's own ADB
 * daemon has something to present. The daemon identifies us by the *public key*
 * inside it — that is what it remembers after pairing — so the fields around it
 * are ceremony. They are still spelled correctly, because a parser that dislikes
 * the encoding fails in ways that are miserable to debug.
 */
internal object SelfSignedCert {

    private const val SEQUENCE = 0x30
    private const val SET = 0x31
    private const val INTEGER = 0x02
    private const val BIT_STRING = 0x03
    private const val OCTET_STRING = 0x04
    private const val NULL = 0x05
    private const val OID = 0x06
    private const val BOOLEAN = 0x01
    private const val UTF8_STRING = 0x0C
    private const val UTC_TIME = 0x17
    private const val GENERALIZED_TIME = 0x18
    private const val CONTEXT_0 = 0xA0
    private const val CONTEXT_3 = 0xA3

    private const val SIGNATURE_ALGORITHM = "SHA256withRSA"
    private const val OID_SHA256_RSA = "1.2.840.113549.1.1.11"
    private const val OID_COMMON_NAME = "2.5.4.3"
    private const val OID_BASIC_CONSTRAINTS = "2.5.29.19"
    private const val OID_KEY_USAGE = "2.5.29.15"
    private const val OID_SUBJECT_KEY_ID = "2.5.29.14"

    /**
     * @param commonName the CN of both subject and issuer — self-signed, so they
     *   are the same name.
     * @param validForYears how long before the daemon starts refusing the
     *   certificate. Generous on purpose: an expiry means pairing all over
     *   again, and there is nothing to rotate away from.
     */
    fun create(
        keyPair: KeyPair,
        commonName: String,
        validForYears: Int = 20,
        serial: BigInteger = BigInteger(64, java.security.SecureRandom()).let {
            // Must be positive and non-zero; RFC 5280 says no more than 20 octets.
            if (it.signum() > 0) it else BigInteger.ONE
        },
    ): X509Certificate {
        val notBefore = Calendar.getInstance(UTC).apply {
            // Backdated slightly so a phone whose clock lags the one that issued
            // the certificate does not reject it as not-yet-valid.
            add(Calendar.DAY_OF_YEAR, -1)
        }.time
        val notAfter = Calendar.getInstance(UTC).apply {
            add(Calendar.YEAR, validForYears)
        }.time

        val name = name(commonName)
        val algorithm = algorithmId()
        val spki = keyPair.public.encoded // already a DER SubjectPublicKeyInfo

        val tbs = der(
            SEQUENCE,
            der(CONTEXT_0, der(INTEGER, byteArrayOf(2))), // v3
            der(INTEGER, serial.toByteArray()),
            algorithm,
            name,
            der(SEQUENCE, time(notBefore), time(notAfter)),
            name,
            spki,
            der(CONTEXT_3, der(SEQUENCE, *extensions(spki))),
        )

        val signature = Signature.getInstance(SIGNATURE_ALGORITHM).run {
            initSign(keyPair.private)
            update(tbs)
            sign()
        }

        val encoded = der(
            SEQUENCE,
            tbs,
            algorithm,
            der(BIT_STRING, byteArrayOf(0) + signature), // 0 unused bits
        )

        // Round-tripping through the platform's own parser is the check that
        // matters: whatever reads this later is a CertificateFactory too, so if
        // this call survives, so will theirs.
        return CertificateFactory.getInstance("X.509")
            .generateCertificate(encoded.inputStream()) as X509Certificate
    }

    private val UTC: TimeZone get() = TimeZone.getTimeZone("UTC")

    private fun extensions(spki: ByteArray): Array<ByteArray> = arrayOf(
        // Self-signed, so it signs its own certificate: CA:TRUE.
        extension(OID_BASIC_CONSTRAINTS, critical = true, value = der(SEQUENCE, der(BOOLEAN, byteArrayOf(0xFF.toByte())))),
        // digitalSignature (0), keyEncipherment (2), keyCertSign (5).
        extension(OID_KEY_USAGE, critical = true, value = der(BIT_STRING, byteArrayOf(2, 0xA4.toByte()))),
        extension(OID_SUBJECT_KEY_ID, critical = false, value = der(OCTET_STRING, keyIdentifier(spki))),
    )

    private fun extension(oid: String, critical: Boolean, value: ByteArray): ByteArray {
        val parts = mutableListOf(oid(oid))
        // DEFAULT FALSE: DER forbids encoding the default, so only TRUE appears.
        if (critical) parts += der(BOOLEAN, byteArrayOf(0xFF.toByte()))
        parts += der(OCTET_STRING, value)
        return der(SEQUENCE, *parts.toTypedArray())
    }

    /** SHA-1 of the subjectPublicKey bit string, as RFC 5280 §4.2.1.2 asks. */
    private fun keyIdentifier(spki: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-1").digest(subjectPublicKeyBits(spki))

    /**
     * Pulls the raw key bits out of a SubjectPublicKeyInfo:
     * `SEQUENCE { AlgorithmIdentifier, BIT STRING }`. Skips the algorithm, then
     * drops the BIT STRING's leading unused-bit count.
     */
    private fun subjectPublicKeyBits(spki: ByteArray): ByteArray {
        var i = 0
        fun length(): Int {
            val first = spki[i++].toInt() and 0xFF
            if (first < 0x80) return first
            var value = 0
            repeat(first and 0x7F) { value = (value shl 8) or (spki[i++].toInt() and 0xFF) }
            return value
        }
        i++ // outer SEQUENCE tag
        length()
        i++ // AlgorithmIdentifier tag
        i += length() // its body
        i++ // BIT STRING tag
        val bits = length()
        i++ // unused-bit count, always 0 for a key
        return spki.copyOfRange(i, i + bits - 1)
    }

    private fun algorithmId(): ByteArray =
        der(SEQUENCE, oid(OID_SHA256_RSA), der(NULL, ByteArray(0)))

    /** `RDNSequence` holding a single CN. */
    private fun name(commonName: String): ByteArray = der(
        SEQUENCE,
        der(
            SET,
            der(SEQUENCE, oid(OID_COMMON_NAME), der(UTF8_STRING, commonName.toByteArray(Charsets.UTF_8))),
        ),
    )

    /**
     * RFC 5280: UTCTime up to and including 2049, GeneralizedTime after. Getting
     * this backwards is a favourite way to produce a certificate that parses
     * everywhere except where it matters.
     */
    private fun time(date: Date): ByteArray {
        val calendar = Calendar.getInstance(UTC).apply { time = date }
        val utc = calendar.get(Calendar.YEAR) <= 2049
        val pattern = if (utc) "yyMMddHHmmss'Z'" else "yyyyMMddHHmmss'Z'"
        val text = SimpleDateFormat(pattern, Locale.US).apply { timeZone = UTC }.format(date)
        return der(if (utc) UTC_TIME else GENERALIZED_TIME, text.toByteArray(Charsets.US_ASCII))
    }

    private fun oid(dotted: String): ByteArray {
        val parts = dotted.split('.').map { it.toLong() }
        val body = mutableListOf<Byte>()
        body += (parts[0] * 40 + parts[1]).toByte()
        for (part in parts.drop(2)) {
            // Base-128, most significant group first, continuation bit set on
            // every byte but the last.
            val group = ArrayDeque<Byte>()
            var rest = part
            group.addFirst((rest and 0x7F).toByte())
            rest = rest shr 7
            while (rest > 0) {
                group.addFirst(((rest and 0x7F) or 0x80).toByte())
                rest = rest shr 7
            }
            body += group
        }
        return der(OID, body.toByteArray())
    }

    private fun der(tag: Int, vararg body: ByteArray): ByteArray {
        val content = if (body.size == 1) body[0] else body.reduceOrNull(ByteArray::plus) ?: ByteArray(0)
        return byteArrayOf(tag.toByte()) + length(content.size) + content
    }

    private fun length(size: Int): ByteArray {
        if (size < 0x80) return byteArrayOf(size.toByte())
        var remaining = size
        val bytes = ArrayDeque<Byte>()
        while (remaining > 0) {
            bytes.addFirst((remaining and 0xFF).toByte())
            remaining = remaining ushr 8
        }
        return byteArrayOf((0x80 or bytes.size).toByte()) + bytes.toByteArray()
    }
}
