package com.btjuicer.adb

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.Certificate
import java.util.Calendar
import javax.security.auth.x500.X500Principal

/**
 * The identity this phone presents to its own ADB daemon.
 *
 * Generated once and kept in the Android keystore. That matters for usability:
 * ADB remembers the key you paired with, so pairing is a one-time ritual and
 * every later reconnection — after a reboot, say — needs nothing but the connect
 * port. Lose the key and you pair again.
 *
 * AndroidKeyStore is also the only public API that hands back a *self-signed
 * certificate* along with the key, which the TLS handshake needs; building an
 * X.509 by hand would mean dragging in a crypto library for one certificate.
 */
object AdbKeys {

    private const val ALIAS = "btjuicer-adb"
    private const val PROVIDER = "AndroidKeyStore"

    data class Identity(val privateKey: PrivateKey, val certificate: Certificate)

    fun load(): Identity? = runCatching {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        val key = store.getKey(ALIAS, null) as? PrivateKey ?: return null
        val certificate = store.getCertificate(ALIAS) ?: return null
        Identity(key, certificate)
    }.getOrNull()

    fun loadOrCreate(): Identity? = load() ?: create()

    /** Wipes the identity, which also invalidates the pairing on the daemon side. */
    fun clear() {
        runCatching {
            KeyStore.getInstance(PROVIDER).apply { load(null) }.deleteEntry(ALIAS)
        }
    }

    private fun create(): Identity? = runCatching {
        val notBefore = Calendar.getInstance()
        val notAfter = Calendar.getInstance().apply { add(Calendar.YEAR, 20) }

        val spec = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setKeySize(2048)
            .setDigests(
                KeyProperties.DIGEST_SHA1,
                KeyProperties.DIGEST_SHA256,
                KeyProperties.DIGEST_SHA512,
            )
            .setSignaturePaddings(
                KeyProperties.SIGNATURE_PADDING_RSA_PKCS1,
                KeyProperties.SIGNATURE_PADDING_RSA_PSS,
            )
            .setCertificateSubject(X500Principal("CN=BT Juicer"))
            .setCertificateSerialNumber(BigInteger.ONE)
            .setCertificateNotBefore(notBefore.time)
            .setCertificateNotAfter(notAfter.time)
            .build()

        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, PROVIDER).apply {
            initialize(spec)
            generateKeyPair()
        }
        load()
    }.getOrNull()
}
