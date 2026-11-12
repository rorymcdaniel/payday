package app.payday

import android.os.Bundle
import android.provider.Settings
import android.content.Intent
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

class MainActivity : FragmentActivity() {
    private val model: PaydayModel by viewModels()
    private var unlocked: Boolean
        get() = model.unlocked
        set(value) { model.unlocked = value }
    private var authenticating = false
    private var lockMessage by mutableStateOf("Use your fingerprint or phone screen lock to open Payday.")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setContent {
            PaydayTheme {
                if (unlocked) {
                    DisposableEffect(model.busy) {
                        if (model.busy) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        onDispose { window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
                    }
                }
                PaydaySession(model) {
                    LockScreen(lockMessage, ::unlock) {
                        startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                    }
                }
            }
        }
    }
    override fun onResume() { super.onResume(); if (!unlocked && !authenticating) unlock() }
    override fun onStop() {
        if (!isChangingConfigurations && !authenticating) unlocked = false
        super.onStop()
    }
    private fun unlock() {
        if (authenticating) return
        val methods = BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL
        if (BiometricManager.from(this).canAuthenticate(methods) != BiometricManager.BIOMETRIC_SUCCESS) {
            lockMessage = "Set up a phone screen lock or fingerprint in Android Settings, then return to Payday."
            return
        }
        authenticating = true
        val prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                authenticating = false; unlocked = true; model.open()
            }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                authenticating = false; lockMessage = "Payday is locked. ${errString}"
            }
        })
        prompt.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle("Unlock Payday")
            .setSubtitle("Your budget, just for you").setAllowedAuthenticators(methods).build())
    }
}
