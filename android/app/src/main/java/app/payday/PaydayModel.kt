package app.payday

import android.app.Application
import android.net.Uri
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class Page(val title: String) { Paycheck("Paycheck"), Defaults("Defaults"), History("History"), Settings("Settings") }
class PaydayModel @JvmOverloads constructor(application: Application, private val practiceOnly: Boolean = false) : AndroidViewModel(application) {
    private val app = application
    var unlocked by mutableStateOf(false)
    private val preferences = app.getSharedPreferences("mode", 0)
    var practice by mutableStateOf(practiceOnly || preferences.getBoolean("practice", false)); private set
    var state by mutableStateOf(AppState()); private set
    var page by mutableStateOf(Page.Settings)
    var busy by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null)
    var notice by mutableStateOf<String?>(null)
    var fatal by mutableStateOf<String?>(null); private set
    var connected by mutableStateOf(false); private set
    var snapshot by mutableStateOf<Snapshot?>(null); private set
    var plans by mutableStateOf<List<Plan>>(emptyList()); private set
    var incomes by mutableStateOf<List<Income>>(emptyList()); private set
    var reviewed by mutableStateOf<Operation?>(null)
    var incoming by mutableStateOf<Transfer?>(null)
    var inputRevision by mutableIntStateOf(0); private set
    val invalidFields = mutableStateMapOf<String, Boolean>()
    private var store: SQLiteStore? = null
    private var engine: AllocationEngine? = null
    private val vault = TokenVault(app)
    val plan get() = state.selectedPlan
    val defaults get() = state.defaults[plan?.id].orEmpty()
    val allocated get() = runCatching { Money.total(state.draft?.contributions.orEmpty().map { it.amount }) }.getOrDefault(0)
    val remaining get() = (state.draft?.amount ?: 0) - allocated
    val canReview get() = connected && !busy && !state.blocked && state.draft?.month == Dates.month() && invalidFields.isEmpty() && remaining == 0L && (state.draft?.amount ?: 0) > 0
    private var opened = false
    fun open() {
        if (opened) return
        opened = true
        work {
            openStore()
            if (connected) refreshData()
            page = if (state.blocked) Page.History else if (connected && plan != null) Page.Paycheck else Page.Settings
        }
    }
    private fun openStore() {
        try {
            store = SQLiteStore(app, practice)
            if (practice) {
                engine = AllocationEngine(store!!, DemoAPI(app)); connected = true
                if (store!!.state.selectedPlan == null) store!!.update { it.copy(selectedPlan = DemoAPI.plan, defaults = mapOf(DemoAPI.plan.id to DemoAPI.defaults)) }
            } else {
                engine = null; connected = false
                try { vault.read()?.let { engine = AllocationEngine(store!!, YNABClient(it)); connected = true } }
                catch (_: Exception) { notice = "Your saved token could not be opened. Reconnect to YNAB; your data is intact." }
            }
            if (!store!!.state.blocked) store!!.update { it.synchronized() }
            sync()
        } catch (e: Exception) { fatal = e.message ?: "Could not open saved data."; throw e }
    }
    private fun sync() { store?.let { state = it.state } }
    fun money(amount: Long) = Money.format(amount, plan)
    fun work(action: suspend () -> Unit) {
        if (busy || fatal != null) return
        busy = true; error = null; notice = null
        viewModelScope.launch {
            try { action() }
            catch (e: Exception) { error = e.message ?: "The operation could not be completed. Check History if applying was in progress." }
            finally { sync(); busy = false }
        }
    }
    fun edit(change: (AppState) -> AppState) {
        if (busy || reviewed != null || fatal != null) return
        try { store?.update { change(it).synchronized() }; sync() }
        catch (_: Exception) { error = "Could not save your change. The last saved values are still in place."; inputRevision++ }
    }
    fun refresh() = work { refreshData() }
    private suspend fun refreshData() {
        val api = engine?.api ?: return
        plans = api.plans()
        val selected = plan ?: return
        val live = plans.find { it.id == selected.id }
        ensure(live?.currency == selected.currency && live?.digits == selected.digits, "The selected budget is unavailable or its currency changed. Check Settings.")
        snapshot = api.snapshot(selected.id, state.draft?.month ?: Dates.month())
        try { incomes = api.incomes(selected.id) } catch (_: Exception) { incomes = emptyList(); notice = "Budget refreshed. Recent deposits could not be loaded; enter a paycheck manually." }
        if (state.draft == null && !state.blocked) createDraft()
    }
    private fun createDraft() {
        val selected = plan ?: return
        val rows = defaults.map { it.copy(normal = it.amount) }
        store!!.update { it.copy(draft = Draft(planID = selected.id, contributions = rows, normalContributions = rows, amount = if (practice) 4_123_720 else 0)) }
        sync(); invalidFields.clear(); inputRevision++
    }
    fun newDraft() = work {
        ensure(!state.blocked, "Reconcile the interrupted allocation in History before starting a new paycheck.")
        createDraft(); snapshot = null; incomes = emptyList(); page = Page.Paycheck
        if (connected) refreshData()
    }
    fun connect(raw: String) {
        val token = raw.trim()
        if (token.isEmpty() || token.length > 4096 || !token.all { it.code in 33..126 }) { error = "Paste only your YNAB token, without spaces or line breaks."; return }
        work {
            val api = YNABClient(token); val fetched = api.plans()
            withContext(Dispatchers.IO) { vault.save(token) }
            engine = AllocationEngine(store!!, api); plans = fetched; connected = true
            notice = "Connected. Choose your budget below."
            if (plan != null) refreshData()
        }
    }
    fun disconnect() = work { vault.remove(); connected = false; engine = null; snapshot = null; incomes = emptyList(); plans = emptyList(); page = Page.Settings }
    fun selectPlan(selected: Plan) = work {
        ensure(!state.blocked, "Reconcile the interrupted allocation before switching budgets.")
        ensure(state.defaults[selected.id].orEmpty().all { it.amount % Money.unit(selected.digits) == 0L },
            "This budget’s currency precision changed. Adjust its saved default amounts to the new precision before selecting it.")
        store!!.update { it.copy(selectedPlan = selected, draft = null) }; sync(); createDraft(); refreshData(); page = Page.Paycheck
    }
    fun switchMode() = work {
        ensure(!practiceOnly, "This test session only supports practice mode.")
        reviewed = null; incoming = null; invalidFields.clear(); snapshot = null; plans = emptyList(); incomes = emptyList()
        store?.close(); practice = !practice
        preferences.edit().putBoolean("practice", practice).commit()
        openStore(); if (connected) refreshData(); page = if (state.blocked) Page.History else if (practice) Page.Paycheck else Page.Settings
        inputRevision++
    }
    fun setAmount(amount: Long) = edit { it.copy(draft = it.draft?.copy(amount = amount, incomeID = null, incomeAliases = null, usesReadyToAssign = false)) }
    fun setContribution(id: String, amount: Long, isDefault: Boolean) = edit { s ->
        if (isDefault) s.copy(defaults = s.defaults + (plan!!.id to defaults.map { if (it.categoryID == id) it.copy(amount = amount) else it }))
        else s.copy(draft = s.draft?.copy(contributions = s.draft.contributions.map { if (it.categoryID == id) it.copy(amount = amount) else it }))
    }
    fun addCategory(category: Category, isDefault: Boolean) {
        edit { s ->
            val row = Contribution(category.id, category.name, 0)
            if (isDefault) s.copy(defaults = s.defaults + (plan!!.id to (defaults + row).distinctBy { it.categoryID }))
            else s.copy(draft = s.draft?.copy(contributions = (s.draft.contributions + row).distinctBy { it.categoryID }))
        }
    }
    fun removeCategory(id: String, isDefault: Boolean) {
        edit { s -> if (isDefault) s.copy(defaults = s.defaults + (plan!!.id to defaults.filter { it.categoryID != id }))
            else s.copy(draft = s.draft?.copy(contributions = s.draft.contributions.filter { it.categoryID != id })) }
        invalidFields.remove("${if (isDefault) "default" else "draft"}-$id")
    }
    fun moveDefault(id: String, offset: Int) = edit { s ->
        val rows = defaults.toMutableList(); val index = rows.indexOfFirst { it.categoryID == id }
        if (index >= 0 && index + offset in rows.indices) rows.add(index + offset, rows.removeAt(index))
        s.copy(defaults = s.defaults + (plan!!.id to rows))
    }
    fun promote(row: Contribution) = edit { s ->
        val rows = defaults.toMutableList(); val index = rows.indexOfFirst { it.categoryID == row.categoryID }
        if (index < 0) rows.add(row.copy(normal = 0)) else rows[index] = row.copy(normal = 0)
        s.copy(defaults = s.defaults + (plan!!.id to rows))
    }
    fun saveDefaults() = edit { it.copy(defaults = it.defaults + (plan!!.id to it.draft!!.contributions.map { r -> r.copy(normal = 0) })) }
    fun resetContributions() {
        edit { it.copy(draft = it.draft?.copy(contributions = defaults.map { r -> r.copy(normal = r.amount) }, normalContributions = defaults.map { r -> r.copy(normal = r.amount) })) }
        invalidFields.keys.filter { it.startsWith("draft-") }.forEach { invalidFields.remove(it) }; inputRevision++
    }
    fun remainder(id: String) {
        val row = state.draft?.contributions?.find { it.categoryID == id } ?: return
        if (invalidFields.isEmpty() && row.amount + remaining in 0..Money.limit) { setContribution(id, row.amount + remaining, false); inputRevision++ }
    }
    fun useReady() = work {
        ensure(!state.blocked, "An allocation needs attention in History.")
        val live = engine!!.api.snapshot(plan!!.id, Dates.month())
        if (state.draft == null) createDraft()
        store!!.update { it.copy(draft = it.draft!!.useReady(live, it.history, plan!!.digits)) }
        snapshot = live; inputRevision++; invalidFields.remove("paycheck")
    }
    fun chooseIncome(income: Income) {
        if (income.amount % Money.unit(plan?.digits ?: 2) != 0L) {
            error = "This deposit contains more precision than your budget currency supports. Correct the fractional amount in YNAB first."
            return
        }
        edit { it.copy(draft = it.draft?.copy(amount = income.amount, date = income.date, reference = income.name, incomeID = income.id, incomeAliases = income.aliases, usesReadyToAssign = false)) }
        inputRevision++; invalidFields.remove("paycheck")
    }
    fun review() { if (canReview) work { reviewed = engine!!.review(state.draft!!, plan!!) } }
    fun apply() {
        val operation = reviewed ?: return
        reviewed = null
        work { page = Page.History; engine!!.apply(operation) { sync() }; snapshot = null; notice = "Allocation complete. Every contribution was verified." }
    }
    fun inspect(id: String) = work { ensure(connected, "Connect to YNAB first."); engine!!.inspect(id); notice = "Observed assignments refreshed. A match alone does not prove which app made a change." }
    fun reconcile(id: String, note: String) = work {
        // Reconciliation is a local record and remains available even when disconnected.
        ensure(note.trim().length >= 12, "Describe what you checked and corrected in YNAB (at least 12 characters).")
        ensure(state.history.any { it.id == id && it.blocksWrites }, "This allocation does not need reconciliation.")
        store!!.update { it.copy(history = it.history.map { op -> if (op.id == id) op.copy(status = OperationStatus.reconciled, reconciliationNote = note.trim(), resolvedAt = java.time.Instant.now().toString()) else op }) }
        notice = "Reconciliation recorded. This paycheck remains reserved in History."
    }
    fun readImport(uri: Uri) = work {
        val data = withContext(Dispatchers.IO) { app.contentResolver.openInputStream(uri)?.use { it.readNBytes(Transfers.maxBytes + 1) } ?: throw PaydayException("Could not open this file.") }
        val transfer = Transfers.decode(data, practice)
        Transfers.merge(state, transfer) // Validate before showing a confirmation.
        incoming = transfer
    }
    fun confirmImport() {
        val transfer = incoming ?: return
        incoming = null
        work {
            store!!.update { Transfers.merge(it, transfer) }; sync(); reviewed = null; invalidFields.clear(); inputRevision++
            snapshot = null; incomes = emptyList(); page = if (state.blocked) Page.History else if (connected) Page.Paycheck else Page.Settings
            notice = "Imported ${transfer.state.history.size} history records and your saved setup. ${if (!connected) "Connect to YNAB to continue." else "Refresh YNAB before allocating."}"
        }
    }
    fun export(uri: Uri) = work {
        val bytes = Transfers.encode(state, practice)
        withContext(Dispatchers.IO) { app.contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) } ?: throw PaydayException("Could not save the transfer.") }
        notice = "Transfer saved, including defaults, draft, and history. Your token is excluded."
    }
    override fun onCleared() { store?.close() }
}
