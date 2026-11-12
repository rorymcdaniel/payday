package app.payday

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import kotlinx.serialization.encodeToString
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SQLiteStore(context: Context, practice: Boolean) : StateStore {
    private val db: SQLiteDatabase
    @Volatile override var state: AppState = AppState()
        private set
    init {
        val file = context.getDatabasePath(if (practice) "practice.sqlite" else "payday.sqlite")
        file.parentFile!!.mkdirs()
        db = SQLiteDatabase.openOrCreateDatabase(file, null)
        try {
            db.rawQuery("PRAGMA journal_mode=DELETE", null).use { it.moveToFirst() }
            db.execSQL("PRAGMA synchronous=FULL")
            db.execSQL("CREATE TABLE IF NOT EXISTS app_state (id INTEGER PRIMARY KEY CHECK(id=1), document TEXT NOT NULL)")
            db.rawQuery("SELECT document FROM app_state WHERE id=1", null).use { cursor ->
                if (cursor.moveToFirst()) state = Transfers.decodeState(cursor.getString(0))
            }
            update { it.copy(history = it.history.map(Operation::recovered)) }
        } catch (e: Exception) { db.close(); throw PaydayException("Payday could not open its saved data. Your history has been retained. ${e.message.orEmpty()}") }
    }
    @Synchronized override fun update(change: (AppState) -> AppState) {
        val next = change(state)
        val document = paydayJson.encodeToString(next)
        db.beginTransaction()
        try {
            db.insertWithOnConflict("app_state", null, ContentValues().apply { put("id", 1); put("document", document) }, SQLiteDatabase.CONFLICT_REPLACE).also {
                ensure(it != -1L, "Could not save local history. No further YNAB changes will be sent.")
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        state = next // Publish only after the FULL synchronous transaction commits.
    }
    fun close() { db.close() }
}
class TokenVault(context: Context, private val alias: String = "app.payday.ynab") {
    private val file = AtomicFile(File(context.noBackupFilesDir, "ynab-token"))
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUnlockedDeviceRequired(true).build())
        }.generateKey()
    }
    fun read(): String? {
        if (!file.baseFile.exists()) return null
        val bytes = file.readFully()
        ensure(bytes.size in 29..8192, "Saved token is unreadable. Reconnect to YNAB.")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
    }
    fun save(token: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key())
        val output = file.startWrite()
        try { output.write(cipher.iv + cipher.doFinal(token.toByteArray())); file.finishWrite(output) }
        catch (e: Exception) { file.failWrite(output); throw e }
    }
    fun remove() { file.delete() }
}
class DemoAPI(context: Context) : BudgetAPI {
    companion object {
        val plan = Plan("demo", "My practice budget")
        val defaults = listOf(Contribution("home", "Rent & home", 1_800_000), Contribution("groceries", "Groceries", 400_000),
            Contribution("gas", "Gasoline", 100_000), Contribution("dining", "Dining out", 100_000), Contribution("utilities", "Utilities", 175_000),
            Contribution("car", "Car repair", 225_000), Contribution("savings", "Emergency fund", 1_000_000), Contribution("fun", "Fun & adventures", 275_000))
    }
    private val file = AtomicFile(File(context.noBackupFilesDir, "practice-budget.json"))
    private var value: Snapshot = if (file.baseFile.exists()) paydayJson.decodeFromString(file.readFully().toString(Charsets.UTF_8)) else
        Snapshot(Dates.month(), 8_247_440, defaults.mapIndexed { i, row -> Category(row.categoryID, row.name, if (i < 5) "Everyday" else "Looking ahead",
            if (i == 1) 500_000 else 0, when (i) { 1 -> 35_000; 5 -> 2_000_000; 6 -> 6_400_000; else -> 0 }, true) } + Category("gifts", "Gifts", "Looking ahead", 0, 80_000, true))
    override suspend fun plans() = listOf(plan)
    override suspend fun snapshot(planID: String, month: String) = value.copy(month = month)
    override suspend fun incomes(planID: String) = listOf(Income("practice-paycheck-${Dates.day()}", Dates.day(), "Example employer", 4_123_720))
    override suspend fun assign(planID: String, month: String, categoryID: String, budgeted: Long): Long {
        val category = value.categories.first { it.id == categoryID }; val difference = budgeted - category.budgeted
        val next = value.copy(month = month, readyToAssign = value.readyToAssign - difference,
            categories = value.categories.map { if (it.id == categoryID) it.copy(budgeted = budgeted, balance = it.balance + difference) else it })
        val output = file.startWrite()
        try { output.write(paydayJson.encodeToString(next).toByteArray()); file.finishWrite(output); value = next }
        catch (e: Exception) { file.failWrite(output); throw e }
        return budgeted
    }
}
