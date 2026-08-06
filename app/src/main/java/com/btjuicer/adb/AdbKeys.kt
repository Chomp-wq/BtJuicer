package com.btjuicer.adb

import android.content.Context
import android.util.Log
import java.io.File
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec

/**
 * The identity this phone presents to its own ADB daemon.
 *
 * Generated once and kept in the app's private storage. That matters for
 * usability: ADB remembers the key you paired with, so pairing is a one-time
 * ritual and every later reconnection — after a reboot, say — needs nothing but
 * the connect port. Lose the key and you pair again.
 *
 * ### Why not the Android keystore
 *
 * The first version put the key in AndroidKeyStore, which is where a key
 * belongs: hardware-backed and impossible to extract. It does not work here.
 * A keystore key never leaves the secure element, so every RSA operation is a
 * request to it, and the TLS 1.3 handshake ADB uses asks for RSA-PSS signatures
 * that the element declines to serve — the handshake dies inside Conscrypt with
 * `error:04000044:RSA routines:internal error`, several layers below anywhere
 * the failure could be interpreted.
 *
 * So the key is generated in software and written to `filesDir`, which is
 * private to this app: readable by this app, by root, and by nothing else. The
 * honest way to put that is that the key is as safe as the phone — an attacker
 * who already has root can read it, and an attacker who already has root did
 * not need it. It is worth being clear about what the key is, though: it
 * authorises shell access to this phone. [clear] deletes it, and unpairing from
 * Android's wireless-debugging screen revokes it from the other side.
 */
object AdbKeys {

    private const val TAG = "BTJuicerAdb"
    private const val KEY_FILE = "adb_identity.pk8"
    private const val CERT_FILE = "adb_identity.der"
    private const val KEY_SIZE = 2048
    private const val COMMON_NAME = "BT Juicer"

    /** The AndroidKeyStore alias the first version used; cleaned up on sight. */
    private const val LEGACY_ALIAS = "btjuicer-adb"

    data class Identity(val privateKey: PrivateKey, val certificate: Certificate)

    fun load(context: Context): Identity? = runCatching {
        val keyFile = context.file(KEY_FILE)
        val certFile = context.file(CERT_FILE)
        if (!keyFile.exists() || !certFile.exists()) return null

        val privateKey = KeyFactory.getInstance("RSA")
            .generatePrivate(PKCS8EncodedKeySpec(keyFile.readBytes()))
        val certificate = CertificateFactory.getInstance("X.509")
            .generateCertificate(certFile.inputStream())
        Identity(privateKey, certificate)
    }.getOrElse {
        Log.w(TAG, "stored identity unreadable, regenerating", it)
        // A half-written or corrupt pair is worse than none: it would fail every
        // connection forever. Drop it and let the caller make a fresh one.
        clear(context)
        null
    }

    fun loadOrCreate(context: Context): Identity? = load(context) ?: create(context)

    /** Wipes the identity, which also invalidates the pairing on the daemon side. */
    fun clear(context: Context) {
        runCatching { context.file(KEY_FILE).delete() }
        runCatching { context.file(CERT_FILE).delete() }
        clearLegacy()
    }

    private fun create(context: Context): Identity? = runCatching {
        clearLegacy()

        val pair: KeyPair = KeyPairGenerator.getInstance("RSA")
            .apply { initialize(KEY_SIZE) }
            .generateKeyPair()
        val certificate = SelfSignedCert.create(pair, COMMON_NAME)

        // Written key-last so a load() interrupted midway finds no key file and
        // treats the identity as absent rather than as broken.
        context.file(CERT_FILE).writeBytes(certificate.encoded)
        context.file(KEY_FILE).writeBytes(pair.private.encoded)

        Identity(pair.private, certificate)
    }.getOrElse {
        Log.w(TAG, "could not create an ADB identity", it)
        null
    }

    private fun clearLegacy() {
        runCatching {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(LEGACY_ALIAS)
        }
    }

    private fun Context.file(name: String) = File(filesDir, name)
}
