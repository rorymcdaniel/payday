package app.payday

import android.app.DatePickerDialog
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import java.time.LocalDate

private val forest = Color(0xFF214A3D)
private val paper = Color(0xFFF7F7F0)
@Composable fun PaydayTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val colors = if (dark) darkColorScheme(primary = Color(0xFFABD3B9), secondary = Color(0xFFE8CC7D),
        primaryContainer = Color(0xFF294B39), secondaryContainer = Color(0xFF344B3D), onSecondaryContainer = Color(0xFFDCECDC),
        background = Color(0xFF141C18), surface = Color(0xFF1E2922), surfaceContainer = Color(0xFF202D24))
        else lightColorScheme(primary = forest, secondary = Color(0xFF716137), primaryContainer = Color(0xFFDDE9DC),
            secondaryContainer = Color(0xFFDEE8D9), onSecondaryContainer = forest, background = paper, surface = Color.White,
            surfaceVariant = Color(0xFFE9EEE5), surfaceContainer = Color(0xFFEEF0E7))
    MaterialTheme(colorScheme = colors, content = content)
}
@Composable fun LockScreen(message: String, unlock: () -> Unit, settings: () -> Unit) {
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.safeDrawingPadding().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Default.Lock, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.height(20.dp)); Text("payday", style = MaterialTheme.typography.headlineLarge)
            Spacer(Modifier.height(12.dp)); Text(message)
            Spacer(Modifier.height(24.dp)); Button(unlock) { Text("Unlock Payday") }
            TextButton(settings) { Text("Android security settings") }
        }
    }
}
@Composable fun PaydaySession(model: PaydayModel, lockedContent: @Composable () -> Unit) {
    // The picker stops the Activity and locks Payday. Keep result registrations outside
    // the authentication gate, and defer file access until the user unlocks again.
    var pendingImport by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingExport by rememberSaveable { mutableStateOf<String?>(null) }
    val importFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { pendingImport = it?.toString() }
    val exportFile = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { pendingExport = it?.toString() }
    LaunchedEffect(model.unlocked, model.busy, pendingImport, pendingExport) {
        if (model.unlocked && !model.busy) {
            val importURI = pendingImport
            val exportURI = pendingExport
            if (importURI != null) {
                pendingImport = null
                model.readImport(Uri.parse(importURI))
            } else if (exportURI != null) {
                pendingExport = null
                model.export(Uri.parse(exportURI))
            }
        }
    }
    if (model.unlocked) PaydayApp(model,
        { importFile.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) },
        { exportFile.launch(if (model.practice) "Payday-practice-transfer.json" else "Payday-transfer.json") })
    else lockedContent()
}
@OptIn(ExperimentalMaterial3Api::class)
private @Composable fun PaydayApp(model: PaydayModel, import: () -> Unit, export: () -> Unit) {
    var categoryPicker by rememberSaveable { mutableStateOf<Boolean?>(null) }
    var confirmation by remember { mutableStateOf<Confirmation?>(null) }
    val ask: (String, String, () -> Unit) -> Unit = { title, message, action -> confirmation = Confirmation(title, message, action) }
    BackHandler(enabled = model.reviewed != null || categoryPicker != null) { if (!model.busy) { model.reviewed = null; categoryPicker = null } }
    Scaffold(
        topBar = {
            TopAppBar(title = { Column { Text(if (model.reviewed != null) "Review allocation" else "payday", fontWeight = FontWeight.SemiBold)
                Text(if (model.practice) "PRACTICE · No real money moves" else model.plan?.name ?: "A calmer payday starts here", style = MaterialTheme.typography.labelSmall) } },
                navigationIcon = { if (model.reviewed != null) IconButton({ model.reviewed = null }, enabled = !model.busy) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to edit") } },
                actions = { if (model.connected && model.reviewed == null) IconButton(model::refresh, enabled = !model.busy) { Icon(Icons.Default.Refresh, "Refresh YNAB") } })
        },
        bottomBar = {
            if (model.reviewed == null) NavigationBar {
                Page.entries.forEach { page -> NavigationBarItem(selected = model.page == page, enabled = !model.busy, onClick = { model.page = page }, label = { Text(page.title) },
                    icon = { Icon(when (page) { Page.Paycheck -> Icons.Default.AddCircle; Page.Defaults -> Icons.Default.Edit; Page.History -> if (model.state.blocked) Icons.Default.Warning else Icons.Default.DateRange; Page.Settings -> Icons.Default.Settings }, null) }) }
            }
        }
    ) { padding ->
        Column(Modifier.padding(padding).consumeWindowInsets(padding).imePadding().fillMaxSize()) {
            if (model.busy) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text("Working… Keep Payday open while applying.", Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelSmall) }
            model.error?.let { Banner(it, true) { model.error = null } }
            model.notice?.let { Banner(it, false) { model.notice = null } }
            if (model.fatal != null) {
                Text("Payday couldn’t open", Modifier.padding(24.dp), style = MaterialTheme.typography.headlineSmall)
                Text(model.fatal!!, Modifier.padding(24.dp))
            } else if (model.reviewed != null) ReviewScreen(model, model.reviewed!!)
            else when (model.page) {
                Page.Paycheck -> PaycheckScreen(model, { categoryPicker = false }, ask)
                Page.Defaults -> DefaultsScreen(model, { categoryPicker = true }, ask)
                Page.History -> HistoryScreen(model, ask)
                Page.Settings -> SettingsScreen(model, import, export, ask)
            }
        }
    }
    if (categoryPicker != null) CategoryPicker(model, categoryPicker!!) { categoryPicker = null }
    confirmation?.let { value -> AlertDialog(onDismissRequest = { confirmation = null }, title = { Text(value.title) }, text = { Text(value.message) },
        confirmButton = { TextButton({ confirmation = null; value.action() }, enabled = !model.busy) { Text("Confirm") } }, dismissButton = { TextButton({ confirmation = null }) { Text("Cancel") } }) }
    model.incoming?.let { transfer ->
        AlertDialog(onDismissRequest = { model.incoming = null }, title = { Text("Import your Payday setup?") }, text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("${transfer.state.selectedPlan?.name ?: "No selected budget"}\n${transfer.state.defaults.values.sumOf { it.size }} default categories\n${transfer.state.history.size} history records\n${if (transfer.state.draft != null) "Includes a saved draft" else "No saved draft"}")
                Text("Exported ${transfer.exportedAt.take(10)} from ${transfer.source}.")
                Text("This replaces the phone’s current draft and the imported budgets’ defaults. Existing phone history is retained. Your YNAB token stays on this phone.")
                Text("Use a fresh export if you allocated on the Mac after saving this file. The apps do not sync.")
            }
        }, confirmButton = { TextButton(model::confirmImport, enabled = !model.busy) { Text("Import data") } }, dismissButton = { TextButton({ model.incoming = null }) { Text("Cancel") } })
    }
}
private data class Confirmation(val title: String, val message: String, val action: () -> Unit)
@Composable private fun Banner(text: String, error: Boolean, dismiss: () -> Unit) {
    Surface(color = if (error) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.secondaryContainer) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(text, Modifier.weight(1f).heightIn(max = 140.dp).verticalScroll(rememberScrollState()).padding(vertical = 12.dp), style = MaterialTheme.typography.bodySmall)
            IconButton(dismiss) { Icon(Icons.Default.Close, "Dismiss message") }
        }
    }
}
@Composable private fun Heading(title: String, subtitle: String) {
    Text(title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
    Spacer(Modifier.height(8.dp)); Text(subtitle, style = MaterialTheme.typography.bodyMedium)
}
@Composable private fun MoneyField(model: PaydayModel, value: Long, fieldID: String, label: String, modifier: Modifier = Modifier, change: (Long) -> Unit) {
    val digits = model.plan?.digits ?: 2
    var text by remember(fieldID, model.inputRevision) { mutableStateOf(TextFieldValue(Money.input(value, digits))) }
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(value, model.inputRevision) {
        if (!focused || !model.invalidFields.containsKey(fieldID)) {
            val formatted = Money.input(value, digits)
            if (formatted != text.text) text = TextFieldValue(formatted, TextRange(formatted.length))
        }
    }
    OutlinedTextField(value = text, onValueChange = { next ->
        try {
            // The IME edits the displayed digits; removing the separator makes Backspace shift cents.
            // A multi-character insertion containing a decimal is a formatted paste.
            val insertion = next.text.length - (text.text.length - (text.selection.max - text.selection.min))
            val amount = if (insertion > 1 && next.text.contains('.') && (text.selection.length == text.text.length || text.text.isEmpty())) Money.parse(next.text, digits)
                else Money.minorEntry(next.text, digits)
            val formatted = Money.input(amount, digits)
            text = TextFieldValue(formatted, TextRange(formatted.length)); model.invalidFields.remove(fieldID); change(amount)
        } catch (_: Exception) { text = next; model.invalidFields[fieldID] = true }
    }, label = { Text(label) }, singleLine = true, isError = model.invalidFields.containsKey(fieldID),
        supportingText = if (model.invalidFields.containsKey(fieldID)) ({ Text("Check this amount") }) else null,
        enabled = !model.busy, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = modifier.onFocusChanged { state ->
            if (state.isFocused && !focused) text = text.copy(selection = TextRange(0, text.text.length))
            focused = state.isFocused
        })
}
@Composable private fun PaycheckScreen(model: PaydayModel, add: () -> Unit, ask: (String, String, () -> Unit) -> Unit) {
    val draft = model.state.draft
    val context = LocalContext.current
    LazyColumn(Modifier.fillMaxSize().testTag("paycheck-list"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { Heading("Give this paycheck a purpose.", "Start with your usual amounts. Make this payday yours.") }
        if (model.state.blocked) item { Card { Column(Modifier.padding(18.dp)) { Text("An allocation needs attention.", fontWeight = FontWeight.Bold); Text("Check its saved steps before allocating another paycheck."); TextButton({ model.page = Page.History }) { Text("Open History") } } } }
        if (model.plan == null) item { Button({ model.page = Page.Settings }) { Text("Connect or import your Mac data") } }
        else if (draft == null) item { Button(model::newDraft, enabled = !model.busy && !model.state.blocked) { Text("New paycheck") } }
        else {
            item {
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
                    Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        MoneyField(model, draft.amount, "paycheck", "Amount to allocate · ${model.plan!!.currency}", Modifier.fillMaxWidth(), model::setAmount)
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            Column { Text("ALLOCATED", style = MaterialTheme.typography.labelSmall); Text(model.money(model.allocated), style = MaterialTheme.typography.titleLarge) }
                            Column(horizontalAlignment = Alignment.End) { Text(if (model.remaining < 0) "OVER ALLOCATED" else "REMAINING", style = MaterialTheme.typography.labelSmall); Text(model.money(kotlin.math.abs(model.remaining)), style = MaterialTheme.typography.titleLarge, color = if (model.remaining < 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary) }
                        }
                        OutlinedButton(model::useReady, enabled = !model.busy && model.connected && !model.state.blocked, modifier = Modifier.fillMaxWidth()) { Text("Use Ready to Assign") }
                        HorizontalDivider()
                        TextButton({
                            val date = runCatching { LocalDate.parse(draft.date) }.getOrDefault(LocalDate.now())
                            DatePickerDialog(context, { _, year, month, day -> model.edit { it.copy(draft = it.draft?.copy(date = LocalDate.of(year, month + 1, day).toString(), incomeID = null, incomeAliases = null, usesReadyToAssign = false)) } }, date.year, date.monthValue - 1, date.dayOfMonth).apply { datePicker.maxDate = System.currentTimeMillis() }.show()
                        }, enabled = !model.busy) { Text("Received ${draft.date}") }
                        OutlinedTextField(draft.reference, { ref -> model.edit { it.copy(draft = it.draft?.copy(reference = ref)) } }, label = { Text("Paycheck reference") }, singleLine = true, enabled = !model.busy, modifier = Modifier.fillMaxWidth())
                        Text("Budget month ${draft.month.take(7)}", style = MaterialTheme.typography.labelMedium)
                        Text("Safe Ready to Assign: ${model.snapshot?.let { model.money(it.readyToAssign) } ?: "refresh to check"}", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            item {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Contributions", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                    var menu by remember { mutableStateOf(false) }
                    Box { IconButton({ menu = true }, enabled = !model.busy) { Icon(Icons.Default.MoreVert, "Paycheck actions") }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem(text = { Text("Start a new paycheck") }, onClick = { menu = false; ask("Start over?", "Your current draft will be replaced with your defaults.", model::newDraft) })
                            DropdownMenuItem(text = { Text("Save allocation as defaults") }, enabled = model.invalidFields.isEmpty(), onClick = { menu = false; ask("Save these defaults?", "This replaces your usual category list and amounts.", model::saveDefaults) })
                            model.incomes.forEach { income -> DropdownMenuItem(text = { Text("Link ${income.date} · ${income.name}\n${model.money(income.amount)}") }, onClick = { menu = false; model.chooseIncome(income) }) }
                        }
                    }
                }
                Row { TextButton({ ask("Use default amounts?", "Replace this paycheck’s contributions with your defaults. The paycheck amount and reference stay the same.", model::resetContributions) }, enabled = !model.busy) { Text("Use default amounts") }
                    TextButton(add, enabled = !model.busy && model.snapshot != null) { Text("Add category") } }
            }
            if (draft.contributions.isEmpty()) item { Text("Add categories here, or set up your usual contributions in Defaults.") }
            items(draft.contributions, key = { it.categoryID }) { ContributionCard(model, it, false, ask) }
            item {
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                    Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(if (model.invalidFields.isNotEmpty()) "Check the highlighted amounts" else if (model.remaining == 0L && draft.amount > 0) "Every dollar has a job." else if (model.remaining < 0) "Reduce contributions by ${model.money(-model.remaining)}" else "${model.money(model.remaining)} still to give a job", fontWeight = FontWeight.SemiBold)
                        Text("Contributions are added to existing assignments. Your draft saves on this phone.", style = MaterialTheme.typography.bodySmall)
                        Button(model::review, enabled = model.canReview, modifier = Modifier.fillMaxWidth()) { Text("Review allocation") }
                        if (!model.connected) TextButton({ model.page = Page.Settings }) { Text("Connect to YNAB to review") }
                    }
                }
            }
        }
    }
}
@Composable private fun ContributionCard(model: PaydayModel, row: Contribution, isDefault: Boolean, ask: (String, String, () -> Unit) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val category = model.snapshot?.categories?.find { it.id == row.categoryID }
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(row.name, fontWeight = FontWeight.SemiBold)
                    Text(if (model.snapshot == null) "Refresh to check availability" else if (category?.eligible != true) "Unavailable · remove or replace" else if (isDefault) category.group else "Available now ${model.money(category.balance)}", style = MaterialTheme.typography.bodySmall,
                        color = if (model.snapshot != null && category?.eligible != true) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Box { IconButton({ menu = true }, enabled = !model.busy) { Icon(Icons.Default.MoreVert, "Actions for ${row.name}") }
                    DropdownMenu(menu, { menu = false }) {
                        if (isDefault) {
                            DropdownMenuItem(text = { Text("Move up") }, onClick = { menu = false; model.moveDefault(row.categoryID, -1) })
                            DropdownMenuItem(text = { Text("Move down") }, onClick = { menu = false; model.moveDefault(row.categoryID, 1) })
                        } else {
                            DropdownMenuItem(text = { Text(if (model.remaining < 0) "Subtract remaining from here" else "Put remaining here") }, enabled = model.invalidFields.isEmpty() && row.amount + model.remaining in 0..Money.limit, onClick = { menu = false; model.remainder(row.categoryID) })
                            DropdownMenuItem(text = { Text("Make this the default amount") }, enabled = model.invalidFields.isEmpty(), onClick = { menu = false; ask("Update ${row.name} default?", "Future paychecks will start with ${model.money(row.amount)} for this category.") { model.promote(row) } })
                        }
                        DropdownMenuItem(text = { Text("Remove category") }, onClick = { menu = false; model.removeCategory(row.categoryID, isDefault) })
                    }
                }
            }
            MoneyField(model, row.amount, "${if (isDefault) "default" else "draft"}-${row.categoryID}", if (isDefault) "Usual contribution" else "Add this paycheck", Modifier.fillMaxWidth().padding(end = 8.dp)) { model.setContribution(row.categoryID, it, isDefault) }
            if (!isDefault && row.amount != row.normal) Text("Normally ${model.money(row.normal)}", Modifier.padding(top = 6.dp), style = MaterialTheme.typography.labelSmall)
        }
    }
}
@Composable private fun DefaultsScreen(model: PaydayModel, add: () -> Unit, ask: (String, String, () -> Unit) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item { Heading("Your usual rhythm.", "Set the contributions you come back to each payday. Use each row’s menu to reorder.") }
        item { Button(add, enabled = !model.busy && model.snapshot != null && model.plan != null) { Text("Add categories") } }
        if (model.plan == null) item { Text("Connect to a budget or import your Mac data first.") }
        else if (model.snapshot == null) item { Text("Connect and refresh YNAB to add categories. Saved amounts can be edited offline.") }
        items(model.defaults, key = { it.categoryID }) { ContributionCard(model, it, true, ask) }
        item { Text("Usual total ${model.money(runCatching { Money.total(model.defaults.map { it.amount }) }.getOrDefault(0))}", style = MaterialTheme.typography.titleMedium) }
    }
}
@Composable private fun CategoryPicker(model: PaydayModel, isDefault: Boolean, dismiss: () -> Unit) {
    var search by remember { mutableStateOf("") }
    val existing = (if (isDefault) model.defaults else model.state.draft?.contributions.orEmpty()).map { it.categoryID }.toSet()
    AlertDialog(onDismissRequest = dismiss, title = { Text("Add categories") }, text = {
        Column { OutlinedTextField(search, { search = it }, label = { Text("Search categories") }, singleLine = true)
            LazyColumn(Modifier.heightIn(max = 380.dp)) {
                items(model.snapshot?.categories.orEmpty().filter { it.eligible && (it.name + it.group).contains(search, true) }) { category ->
                    Row(Modifier.fillMaxWidth().clickable(enabled = category.id !in existing && !model.busy) { model.addCategory(category, isDefault) }.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) { Text(category.name); Text(category.group, style = MaterialTheme.typography.bodySmall) }
                        Icon(if (category.id in existing) Icons.Default.Check else Icons.Default.Add, if (category.id in existing) "Added" else "Add ${category.name}")
                    }
                }
            }
        }
    }, confirmButton = { TextButton(dismiss) { Text("Done") } })
}
@Composable private fun ReviewScreen(model: PaydayModel, op: Operation) {
    var acknowledged by remember(op.id) { mutableStateOf(false) }
    LazyColumn(Modifier.fillMaxSize().testTag("review-list"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { Heading("Ready when you are.", "Add ${Money.format(op.draft.amount, op.plan)} to ${op.plan.name} · ${op.draft.month.take(7)}") }
        item { Text("${op.draft.date} · ${op.draft.reference}"); Text("Ready to Assign: ${Money.format(op.readyBefore, op.plan)}") }
        items(op.steps) { step -> Card { Column(Modifier.fillMaxWidth().padding(16.dp)) {
            Text(step.contribution.name, fontWeight = FontWeight.SemiBold); Text("Add ${Money.format(step.contribution.amount, op.plan)}", style = MaterialTheme.typography.titleLarge)
            Text("Available after ${Money.format(step.beforeBalance + step.contribution.amount, op.plan)}*", style = MaterialTheme.typography.bodySmall)
        } } }
        item { Text("*Assuming no new spending. Contributions increase the existing Assigned amount.", style = MaterialTheme.typography.bodySmall) }
        if (model.state.history.any { it.plan.id == op.plan.id && it.draft.date == op.draft.date && it.draft.amount == op.draft.amount }) item { Text("Another paycheck has this date and amount in History. Verify this is a separate deposit.", color = MaterialTheme.colorScheme.error) }
        item { Text("YNAB updates one category at a time. Keep Payday open and avoid editing YNAB on other devices while this runs. If anything is uncertain, Payday stops and saves what happened.") }
        item { Row(Modifier.fillMaxWidth().clickable { acknowledged = !acknowledged }, verticalAlignment = Alignment.CenterVertically) {
            Checkbox(acknowledged, { acknowledged = it }); Text("These funds are already in Ready to Assign, and I haven’t allocated them before, including on my Mac.", Modifier.weight(1f))
        } }
        item { Button(model::apply, enabled = acknowledged && !model.busy, modifier = Modifier.fillMaxWidth()) { Text(if (model.practice) "Apply to practice budget" else "Confirm & apply ${model.money(op.draft.amount)}") } }
        item { TextButton({ model.reviewed = null }, enabled = !model.busy) { Text("Back to edit") } }
    }
}
@Composable private fun HistoryScreen(model: PaydayModel, ask: (String, String, () -> Unit) -> Unit) {
    var search by rememberSaveable { mutableStateOf("") }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { Heading("Every payday, accounted for.", "Your contributions and anything that needs a closer look.") }
        item { OutlinedTextField(search, { search = it }, label = { Text("Search history") }, modifier = Modifier.fillMaxWidth(), singleLine = true) }
        if (model.state.history.isEmpty()) item { Text("Your next payday starts the story. Confirmed and interrupted allocations appear here.") }
        items(model.state.history.filter { (it.draft.reference + it.draft.date + it.plan.name + it.steps.joinToString { s -> s.contribution.name }).contains(search, true) }, key = { it.id }) { op ->
            var expanded by rememberSaveable(op.id) { mutableStateOf(false) }
            var note by rememberSaveable(op.id) { mutableStateOf("") }
            fun money(value: Long) = Money.format(value, op.plan)
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Column(Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(vertical = 8.dp)) {
                        Text(op.draft.reference, fontWeight = FontWeight.SemiBold)
                        Text(money(op.draft.amount), style = MaterialTheme.typography.headlineSmall)
                        Text("${op.draft.date} · ${op.plan.name}", style = MaterialTheme.typography.bodySmall)
                        Text(when (op.status) { OperationStatus.completed -> "Verified"; OperationStatus.applying -> "Applying…"; OperationStatus.needsAttention -> "Needs attention"; OperationStatus.reconciled -> "Manually reconciled" }, color = if (op.blocksWrites) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
                        Text(if (expanded || op.blocksWrites) "Hide details" else "Show details", style = MaterialTheme.typography.labelSmall)
                    }
                    if (expanded || op.blocksWrites) {
                        HorizontalDivider(); Text("Budget month ${op.draft.month.take(7)}", style = MaterialTheme.typography.labelMedium)
                        op.message?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                        op.steps.forEach { step ->
                            Text("${step.contribution.name} · +${money(step.contribution.amount)}", fontWeight = FontWeight.Medium)
                            Text(when (step.status) { StepStatus.pending -> "Not attempted"; StepStatus.sending -> "In flight"; StepStatus.verified -> "Confirmed"; StepStatus.uncertain -> "Uncertain" }, style = MaterialTheme.typography.labelMedium)
                            Text("Normal ${money(step.contribution.normal)} · change ${money(step.contribution.amount - step.contribution.normal)}", style = MaterialTheme.typography.bodySmall)
                            Text("Assigned before ${money(step.beforeBudgeted)} → intended ${money(step.targetBudgeted)}\nLast observed ${step.observation?.let { money(it) } ?: "unknown"}", style = MaterialTheme.typography.bodySmall)
                        }
                        op.draft.normalContributions.orEmpty().filter { normal -> normal.amount > 0 && op.steps.none { it.contribution.categoryID == normal.categoryID } }.forEach {
                            Text("${it.name} · Not funded · normally ${money(it.amount)}", style = MaterialTheme.typography.bodySmall)
                        }
                        op.reconciliationNote?.let { Text("Your reconciliation: $it") }
                        if (op.blocksWrites && !model.busy) {
                            HorizontalDivider()
                            Text("Check Assigned amounts and recent money moves in YNAB. Correct missing contributions there. If a request may still be pending, wait and verify again. Nothing is retried automatically.", style = MaterialTheme.typography.bodySmall)
                            OutlinedButton({ model.inspect(op.id) }, enabled = model.connected) { Text("Read current YNAB assignments") }
                            OutlinedTextField(note, { note = it }, label = { Text("What did you check or correct?") }, modifier = Modifier.fillMaxWidth())
                            TextButton({ ask("Finish reconciliation?", "This records your note and allows future paychecks. It sends no money and preserves uncertain steps.") { model.reconcile(op.id, note) } }, enabled = note.trim().length >= 12) { Text("Record manual reconciliation") }
                        }
                    }
                }
            }
        }
    }
}
@Composable private fun SettingsScreen(model: PaydayModel, import: () -> Unit, export: () -> Unit, ask: (String, String, () -> Unit) -> Unit) {
    var token by remember { mutableStateOf("") }
    val context = LocalContext.current
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item { Heading(if (model.practice) "Room to practice." else "Your budget. Your phone.", if (model.practice) "A separate sample budget. Try an entire payday without touching YNAB." else "Connect directly to YNAB. Your setup and history stay on this phone.") }
        if (!model.practice) item {
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
                Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(if (model.connected) "Connected to YNAB" else "Connect YNAB", style = MaterialTheme.typography.titleLarge)
                    if (!model.connected) {
                        TextButton({ context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://app.ynab.com/settings/developer"))) }) { Text("Open YNAB developer settings") }
                        OutlinedTextField(token, { token = it }, label = { Text("Personal Access Token") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth(), enabled = !model.busy)
                        Button({ model.connect(token); token = "" }, enabled = !model.busy && token.isNotBlank()) { Text("Connect") }
                    } else TextButton({ ask("Disconnect YNAB?", "The token will be removed from this phone. Your defaults and history stay here.", model::disconnect) }, enabled = !model.busy) { Text("Disconnect") }
                    Text("Your token is encrypted with Android Keystore and excluded from transfers.", style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        if (model.connected) item {
            Text("Budget", style = MaterialTheme.typography.titleLarge)
            model.plans.forEach { plan ->
                OutlinedButton({ ask("Use ${plan.name}?", "This replaces the current draft. Each budget keeps its own defaults and all history is retained.") { model.selectPlan(plan) } }, enabled = !model.busy && !model.state.blocked && plan != model.plan, modifier = Modifier.fillMaxWidth()) { Text(if (plan == model.plan) "✓ ${plan.name}" else plan.name) }
            }
            if (model.plans.isEmpty()) TextButton(model::refresh, enabled = !model.busy) { Text("Load budgets") }
        }
        item {
            HorizontalDivider(); Spacer(Modifier.height(16.dp)); Text("Local data & privacy", style = MaterialTheme.typography.titleLarge)
            Text("Fingerprint or screen lock is required each time you return. Android backups are disabled. Keep your own transfer file for recovery; it contains financial history.", Modifier.padding(vertical = 12.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(import, enabled = !model.busy && !model.state.blocked) { Text("Import from Mac") }
                TextButton(export, enabled = !model.busy) { Text("Export data backup") }
            }
            Text("YNAB remains the source of truth. Imported history protects recorded paychecks, but an old export cannot include later allocations on another device.", style = MaterialTheme.typography.bodySmall)
        }
        item { OutlinedButton({ ask(if (model.practice) "Return to your real budget?" else "Try practice mode?", "Your real and practice data are kept separately.", model::switchMode) }, enabled = !model.busy) { Text(if (model.practice) "Leave practice mode" else "Try practice mode") } }
        item { Text("Payday 1.0.2 · Personal edition\nIndependent software, not affiliated with or endorsed by YNAB.", style = MaterialTheme.typography.bodySmall) }
    }
}
