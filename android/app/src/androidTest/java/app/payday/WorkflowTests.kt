package app.payday

import android.app.Application
import android.app.Activity
import android.content.Intent
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.runtime.CompositionLocalProvider
import androidx.core.app.ActivityOptionsCompat
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.serialization.encodeToString
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class WorkflowTests {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Test fun importResultSurvivesLockAndUnlock() = documentPickerRoundTrip()
    @Test fun importResultArrivingAfterUnlockIsHandled() = documentPickerRoundTrip(deliverAfterUnlock = true)
    @Test fun canceledPickerDoesNotImport() = documentPickerRoundTrip(canceled = true)
    @Test fun pendingImportSurvivesSavedStateRestoration() = documentPickerRoundTrip(restore = true)
    @Test fun exportResultWaitsForUnlock() = documentPickerRoundTrip(export = true)

    private fun documentPickerRoundTrip(deliverAfterUnlock: Boolean = false, canceled: Boolean = false, restore: Boolean = false, export: Boolean = false) {
        val app = ApplicationProvider.getApplicationContext<Application>()
        app.deleteDatabase("practice.sqlite")
        File(app.noBackupFilesDir, "practice-budget.json").delete()
        lateinit var model: PaydayModel
        compose.runOnUiThread {
            model = PaydayModel(app, practiceOnly = true)
            compose.activity.viewModelStore.put("picker-test", model)
            model.open()
            model.unlocked = true
            model.page = Page.Settings
        }
        compose.waitUntil(10_000) { !model.busy && model.state.draft != null }
        compose.runOnIdle { model.page = Page.Settings }
        val before = model.state
        val file = File(app.cacheDir, "synthetic-picker-transfer.json")
        file.writeBytes(if (export) byteArrayOf() else Transfers.encode(AppState(selectedPlan = Plan("import-fixture", "Synthetic Mac budget")), true))
        var launchedCode: Int? = null
        val registry = object : ActivityResultRegistry() {
            override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
                launchedCode = requestCode
            }
        }
        val owner = object : ActivityResultRegistryOwner { override val activityResultRegistry = registry }
        val restoration = StateRestorationTester(compose)
        restoration.setContent {
            CompositionLocalProvider(LocalActivityResultRegistryOwner provides owner) {
                PaydayTheme { PaydaySession(model) { LockScreen("Locked for test", {}, {}) } }
            }
        }
        compose.onNodeWithText(if (export) "Export data backup" else "Import from Mac").performScrollTo().performClick()
        compose.runOnIdle { assertNotNull(launchedCode); model.unlocked = false }
        compose.onNodeWithText("Unlock Payday").assertIsDisplayed()
        if (deliverAfterUnlock) compose.runOnIdle { model.unlocked = true; model.open() }
        // A document result may arrive before or after biometric authentication completes.
        compose.runOnIdle {
            registry.dispatchResult(launchedCode!!, if (canceled) Activity.RESULT_CANCELED else Activity.RESULT_OK,
                if (canceled) null else Intent().setData(Uri.fromFile(file)))
        }
        if (!deliverAfterUnlock) {
            compose.onNodeWithText("Import your Payday setup?").assertDoesNotExist()
            compose.runOnIdle {
                assertEquals(before, model.state); assertNull(model.incoming); assertFalse(model.busy)
                if (export) assertEquals(0L, file.length())
            }
            if (restore) restoration.emulateSavedInstanceStateRestore()
            compose.runOnIdle { model.unlocked = true; model.open() }
        }
        when {
            canceled -> {
                compose.onNodeWithText("Import your Payday setup?").assertDoesNotExist()
                compose.runOnIdle { assertNull(model.incoming); assertFalse(model.busy) }
            }
            export -> {
                compose.waitUntil(5_000) { !model.busy && file.length() > 0 }
                assertEquals(before, Transfers.decode(file.readBytes(), true).state)
            }
            else -> {
                compose.waitUntil(5_000) { model.incoming != null }
                compose.onNodeWithText("Import your Payday setup?").assertIsDisplayed()
                compose.runOnIdle { assertEquals("import-fixture", model.incoming!!.state.selectedPlan!!.id) }
            }
        }
        compose.runOnIdle { assertEquals(before, model.state); assertNull(model.error) }
    }
    @Test fun practicePaycheckEditingReviewApplyAndHistory() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        // Only the synthetic practice store is reset. No token or real store is read.
        app.deleteDatabase("practice.sqlite")
        File(app.noBackupFilesDir, "practice-budget.json").delete()
        lateinit var model: PaydayModel
        compose.runOnUiThread {
            model = PaydayModel(app, practiceOnly = true)
            compose.activity.viewModelStore.put("practice-test", model)
            model.open()
        }
        compose.waitUntil(10_000) { !model.busy && model.state.draft != null }
        compose.runOnIdle { model.unlocked = true }
        compose.setContent { PaydayTheme { PaydaySession(model) {} } }
        compose.onNodeWithText("Give this paycheck a purpose.").assertIsDisplayed()
        compose.onNodeWithText("Amount to allocate · USD").performTextReplacement("12345")
        compose.runOnIdle { assertEquals(123_450L, model.state.draft!!.amount) }
        // A formatted paste keeps its decimal value, while a digit entry shifts cents.
        compose.onNodeWithText("Amount to allocate · USD").performTextReplacement("4123.72")
        compose.runOnIdle { assertEquals(4_123_720L, model.state.draft!!.amount) }
        compose.onNodeWithText("Defaults").performClick()
        compose.onNodeWithText("Your usual rhythm.").assertIsDisplayed()
        compose.onNodeWithContentDescription("Actions for Rent & home").performClick()
        compose.onNodeWithText("Move down").performClick()
        compose.runOnIdle { assertEquals("groceries", model.defaults.first().categoryID); assertEquals("groceries", model.state.draft!!.contributions.first().categoryID) }
        compose.onNodeWithText("Paycheck").performClick()
        compose.onNodeWithTag("paycheck-list").performScrollToNode(hasText("Emergency fund"))
        compose.onNodeWithContentDescription("Actions for Emergency fund").performClick()
        compose.onNodeWithText("Put remaining here").performClick()
        compose.onNodeWithTag("paycheck-list").performScrollToNode(hasText("Review allocation"))
        compose.onNodeWithText("Review allocation").assertIsEnabled().performClick()
        compose.waitUntil(10_000) { model.reviewed != null && !model.busy }
        compose.onNodeWithText("Ready when you are.").assertIsDisplayed()
        compose.onNodeWithTag("review-list").performScrollToNode(hasText("Apply to practice budget"))
        compose.onNodeWithText("Apply to practice budget").assertIsNotEnabled()
        compose.onNodeWithText("These funds are already in Ready to Assign, and I haven’t allocated them before, including on my Mac.").performClick()
        compose.onNodeWithText("Apply to practice budget").assertIsEnabled().performClick()
        compose.waitUntil(10_000) { !model.busy && model.state.history.isNotEmpty() }
        compose.runOnIdle { assertEquals(OperationStatus.completed, model.state.history.first().status); assertFalse(model.state.blocked); assertNull(model.error) }
        compose.onNodeWithText("Verified").assertIsDisplayed()
        compose.runOnIdle { model.newDraft() }
        compose.waitUntil(10_000) { !model.busy && model.state.draft != null }
        compose.onNodeWithText("Give this paycheck a purpose.").assertIsDisplayed()
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        File(app.getExternalFilesDir(null), "practice-paycheck.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
    @Test fun sqliteCommitsSurviveReopenAndCorruptionFailsClosed() {
        val base = ApplicationProvider.getApplicationContext<Context>()
        val directory = File(base.cacheDir, "store-test-${UUID.randomUUID()}").apply { mkdirs() }
        val context = object : ContextWrapper(base) { override fun getDatabasePath(name: String) = File(directory, name) }
        val row = Contribution("food", "Synthetic groceries", 123_450)
        SQLiteStore(context, true).apply { update { it.copy(selectedPlan = Plan("test", "Test"), defaults = mapOf("test" to listOf(row))) }; close() }
        SQLiteStore(context, true).apply { assertEquals(row, state.defaults["test"]!!.first()); close() }
        val file = context.getDatabasePath("practice.sqlite")
        val db = android.database.sqlite.SQLiteDatabase.openDatabase(file.path, null, 0)
        db.execSQL("UPDATE app_state SET document='not JSON' WHERE id=1"); db.close()
        assertTrue(runCatching { SQLiteStore(context, true) }.isFailure)
        val check = android.database.sqlite.SQLiteDatabase.openDatabase(file.path, null, 0)
        check.rawQuery("SELECT document FROM app_state", null).use { it.moveToFirst(); assertEquals("not JSON", it.getString(0)) }; check.close()
    }

    @Test fun importPreviewRequiresConfirmationAndPersistsSetup() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        app.deleteDatabase("practice.sqlite")
        File(app.noBackupFilesDir, "practice-budget.json").delete()
        lateinit var model: PaydayModel
        compose.runOnUiThread {
            model = PaydayModel(app, practiceOnly = true)
            compose.activity.viewModelStore.put("import-test", model)
            model.open()
        }
        compose.waitUntil(10_000) { !model.busy && model.state.draft != null }
        val before = model.state
        val row = Contribution("food", "Imported groceries", 123_450, 123_450)
        val importedPlan = Plan("import-fixture", "Synthetic Mac budget")
        val state = AppState(selectedPlan = importedPlan, defaults = mapOf(importedPlan.id to listOf(row)), draft = Draft(planID = importedPlan.id, contributions = listOf(row), normalContributions = listOf(row), amount = 123_450))
        val file = File(app.cacheDir, "synthetic-transfer.json")
        file.writeBytes(Transfers.encode(state, true))
        compose.runOnIdle { model.unlocked = true }
        compose.setContent { PaydayTheme { PaydaySession(model) {} } }
        compose.runOnUiThread { model.readImport(Uri.fromFile(file)) }
        compose.waitUntil(10_000) { !model.busy && model.incoming != null }
        compose.runOnIdle { assertEquals(before, model.state) }
        compose.onNodeWithText("Import your Payday setup?").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertEquals(before, model.state); model.readImport(Uri.fromFile(file)) }
        compose.waitUntil(10_000) { !model.busy && model.incoming != null }
        compose.onNodeWithText("Import data").performClick()
        compose.waitUntil(10_000) { !model.busy && model.incoming == null }
        compose.runOnIdle { assertEquals(importedPlan, model.state.selectedPlan); assertEquals(listOf(row), model.defaults); assertEquals(123_450L, model.state.draft!!.amount) }
        SQLiteStore(app, true).apply { assertEquals(importedPlan, this.state.selectedPlan); close() }
    }

    @Test fun tokenUsesKeystoreEncryptionAndRejectsTampering() {
        val base = ApplicationProvider.getApplicationContext<Context>()
        val directory = File(base.cacheDir, "token-test-${UUID.randomUUID()}").apply { mkdirs() }
        val context = object : ContextWrapper(base) { override fun getNoBackupFilesDir() = directory }
        val alias = "app.payday.test.${UUID.randomUUID()}"
        val keyStore = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        try {
            val vault = TokenVault(context, alias)
            assertNull(vault.read())
            vault.save("synthetic-test-token")
            assertEquals("synthetic-test-token", TokenVault(context, alias).read())
            assertNull(keyStore.getKey(alias, null).encoded)
            val file = File(directory, "ynab-token")
            assertFalse(file.readBytes().toString(Charsets.UTF_8).contains("synthetic-test-token"))
            val bytes = file.readBytes(); bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte(); file.writeBytes(bytes)
            assertTrue(runCatching { vault.read() }.isFailure)
            vault.remove(); assertNull(vault.read())
        } finally { keyStore.deleteEntry(alias); directory.deleteRecursively() }
    }
}
