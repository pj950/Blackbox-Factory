extends Control

const Factory = preload("res://simulation/factory.gd")
const Fixtures = preload("res://simulation/fixtures.gd")
const Board = preload("res://presentation/board.gd")
const SaveStore = preload("res://persistence/save_store.gd")
const Feedback = preload("res://presentation/feedback.gd")
const ATLAS = preload("res://assets/factory_tiles.svg")
const MODES: Array[String] = ["plate", "component", "double", "empty", "contract", "double_limited", "maintenance"]
const ITEMS: Array[String] = ["iron_ore", "iron_plate", "component"]
const DIRECTIONS: Array[String] = ["East", "South", "West", "North"]

var model: Factory
var running: bool = false
var active_tool: String = "inspect"
var build_facing: int = 0
var selected := Vector2i(-1, -1)
var board: Board
var build_buttons: Dictionary = {}
var stats_label: Label
var inspector: Label
var message_label: Label
var facing_label: Label
var play_button: Button
var rotate_button: Button
var remove_button: Button
var enabled_toggle: CheckButton
var sink_toggle: CheckButton
var storage_menu: OptionButton
var fixture_menu: OptionButton
var reset_dialog: ConfirmationDialog
var sidebar: ScrollContainer
var mode_label: Label
var order_bar: HBoxContainer
var order_label: Label
var order_progress_label: Label
var accept_button: Button
var upgrade_button: Button
var priority_menu: OptionButton
var flow_label: Label
var reported_orders: int = 0
var save_path: String = "user://saves/slot1.json"
var save_store = SaveStore.new()
var save_button: Button
var load_save_button: Button
var load_dialog: ConfirmationDialog
var repair_button: Button
var maintenance_label: Label
var exit_dialog: ConfirmationDialog
var feedback: Feedback
var sound_button: Button
var settings_path: String = "user://preferences.cfg"
var plan_toggle: CheckButton
var conversion_bar: HBoxContainer
var conversion_label: Label
var conversion_button: Button


func _ready() -> void:
	get_tree().auto_accept_quit = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	feedback = Feedback.new()
	feedback.settings_path = settings_path
	add_child(feedback)
	_build_theme()
	_build_ui()
	_load_fixture()
	if feedback.settings_error != OK:
		message_label.text = "Audio preferences could not be loaded; sound defaults to on."


func _style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style


func _build_theme() -> void:
	theme = Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Bahnschrift", "Segoe UI"])
	theme.default_font = font
	theme.default_font_size = 15
	theme.set_color("font_color", "Label", Color("e0e7df"))
	for control_type: String in ["Button", "OptionButton"]:
		theme.set_stylebox("normal", control_type, _style(Color("2b3334"), Color("4b5755")))
		theme.set_stylebox("hover", control_type, _style(Color("3b4844"), Color("9ac3ac")))
		theme.set_stylebox("pressed", control_type, _style(Color("405e4d"), Color("bad7b6")))
		theme.set_stylebox("disabled", control_type, _style(Color("252b2c"), Color("343d3b")))
		theme.set_color("font_color", control_type, Color("e0e7df"))
		theme.set_color("font_pressed_color", control_type, Color("f0f4e8"))
		theme.set_color("font_hover_color", control_type, Color("ffffff"))
	theme.set_constant("separation", "VBoxContainer", 10)
	theme.set_constant("separation", "HBoxContainer", 10)
	theme.set_constant("h_separation", "GridContainer", 6)
	theme.set_constant("v_separation", "GridContainer", 6)


func _icon(index: int) -> AtlasTexture:
	var texture := AtlasTexture.new()
	texture.atlas = ATLAS
	texture.region = Rect2(index * 32, 0, 32, 32)
	return texture


func _label(text: String, font_size: int = 15, color: Color = Color("e0e7df")) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text: String, icon_index: int, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.icon = _icon(icon_index)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT if not text.is_empty() else HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_constant_override("icon_max_width", 24)
	button.custom_minimum_size = Vector2(42, 40)
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	return button


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)
	var layout := VBoxContainer.new()
	margin.add_child(layout)
	var header := HBoxContainer.new()
	layout.add_child(header)
	var title: Label = _label("BLACKBOX / FACTORY", 25)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	mode_label = _label("M3  /  CONTRACTS", 13, Color("acc7b1"))
	header.add_child(mode_label)
	sound_button = _button("", 16, "Sound on / off")
	sound_button.toggle_mode = true
	sound_button.set_pressed_no_signal(feedback.sound_enabled)
	sound_button.toggled.connect(_set_sound)
	header.add_child(sound_button)
	save_button = _button("", 13, "Save and pause (F5)")
	save_button.pressed.connect(_save_current)
	header.add_child(save_button)
	load_save_button = _button("", 14, "Load saved factory (F9)")
	load_save_button.pressed.connect(func() -> void: load_dialog.popup_centered())
	header.add_child(load_save_button)
	play_button = _button("", 10, "Run / pause simulation (Space)")
	play_button.pressed.connect(_toggle_run)
	header.add_child(play_button)
	stats_label = _label("", 14, Color("b6c2bd"))
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_label.tooltip_text = "Power allocation and demand are measured at the last simulation tick."
	layout.add_child(stats_label)
	order_bar = HBoxContainer.new()
	layout.add_child(order_bar)
	var order_text := VBoxContainer.new()
	order_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_text.add_theme_constant_override("separation", 3)
	order_bar.add_child(order_text)
	order_label = _label("", 17, Color("d7dcc0"))
	order_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	order_text.add_child(order_label)
	order_progress_label = _label("", 14, Color("b4c4bb"))
	order_progress_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	order_text.add_child(order_progress_label)
	accept_button = _button("Accept order", 6, "Accept the next unlocked order; cached goods are counted on the next simulation tick")
	accept_button.pressed.connect(func() -> void: _dispatch({"action": "accept_order"}))
	order_bar.add_child(accept_button)
	upgrade_button = _button("+4 power / 240", 12, "Buy the one-time power expansion from 10 to 14")
	upgrade_button.pressed.connect(func() -> void: _dispatch({"action": "power_upgrade"}))
	order_bar.add_child(upgrade_button)
	conversion_bar = HBoxContainer.new()
	layout.add_child(conversion_bar)
	conversion_label = _label("", 14, Color("b8d5e2"))
	conversion_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	conversion_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	conversion_bar.add_child(conversion_label)
	conversion_button = _button("", 7, "Locate conversion target")
	conversion_button.pressed.connect(_focus_conversion)
	conversion_bar.add_child(conversion_button)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(body)
	sidebar = ScrollContainer.new()
	sidebar.custom_minimum_size.x = 248
	sidebar.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(sidebar)
	var tools := VBoxContainer.new()
	tools.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sidebar.add_child(tools)
	tools.add_child(_label("BUILD", 13, Color("a4b2ad")))
	plan_toggle = CheckButton.new()
	var starter_cost: int = 0
	for entry: Dictionary in Factory.CATALOG.starter_layout:
		starter_cost += int(Factory.CATALOG.buildings[entry.kind].price)
	plan_toggle.text = "O1 layout / %d" % starter_cost
	plan_toggle.tooltip_text = "Show the optional first-shipment layout. Ghosts are not built or purchased."
	plan_toggle.button_pressed = true
	plan_toggle.toggled.connect(func(enabled: bool) -> void:
		board.show_starter_layout = enabled
		board._update_tooltip()
		board.queue_redraw()
	)
	tools.add_child(plan_toggle)
	var grid := GridContainer.new()
	grid.columns = 2
	tools.add_child(grid)
	var group := ButtonGroup.new()
	var kinds: Array[String] = ["source", "belt", "splitter", "smelter", "press", "storage", "delivery", "inspect"]
	var names: Array[String] = ["Source", "Belt", "Splitter", "Furnace", "Press", "Storage", "Delivery", "Inspect"]
	for index: int in range(kinds.size()):
		var kind: String = kinds[index]
		var tip: String = "Inspect a building (right click)"
		if kind != "inspect":
			tip = "%s | %d credits" % [names[index], Factory.CATALOG.buildings[kind].price]
		var button: Button = _button(names[index], index, tip)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.toggle_mode = true
		button.button_group = group
		button.pressed.connect(_select_tool.bind(kind))
		grid.add_child(button)
		build_buttons[kind] = button
	var actions := HBoxContainer.new()
	tools.add_child(actions)
	facing_label = _label("East", 14)
	facing_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(facing_label)
	rotate_button = _button("", 8, "Rotate build direction, or inspected empty building (R)")
	rotate_button.pressed.connect(_rotate)
	actions.add_child(rotate_button)
	remove_button = _button("", 9, "Remove selected empty building (Delete)")
	remove_button.pressed.connect(_remove_selected)
	actions.add_child(remove_button)
	tools.add_child(HSeparator.new())
	tools.add_child(_label("INSPECTION", 13, Color("a4b2ad")))
	inspector = _label("No selection", 14)
	inspector.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inspector.custom_minimum_size.y = 118
	tools.add_child(inspector)
	enabled_toggle = CheckButton.new()
	enabled_toggle.text = "Enabled"
	enabled_toggle.tooltip_text = "Stop processing or supply; existing machine output can still drain."
	enabled_toggle.toggled.connect(_set_enabled)
	tools.add_child(enabled_toggle)
	priority_menu = OptionButton.new()
	for priority: String in ["Power: High", "Power: Normal", "Power: Low"]:
		priority_menu.add_item(priority)
	priority_menu.tooltip_text = "Supply priority for processing machines; equal-priority candidates rotate each tick"
	priority_menu.item_selected.connect(func(index: int) -> void: _dispatch({"action": "priority", "cell": selected, "priority": index}))
	tools.add_child(priority_menu)
	maintenance_label = _label("", 14, Color("dfcd96"))
	maintenance_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tools.add_child(maintenance_label)
	repair_button = _button("Maintain / 40", 15, "10 seconds of downtime; preserves materials and batch progress")
	repair_button.pressed.connect(func() -> void: _dispatch({"action": "repair", "cell": selected}))
	tools.add_child(repair_button)
	storage_menu = OptionButton.new()
	for item: String in ITEMS:
		storage_menu.add_item(item.replace("_", " ").capitalize())
	storage_menu.item_selected.connect(_set_storage)
	tools.add_child(storage_menu)
	tools.move_child(inspector, tools.get_child_count() - 1)
	tools.add_child(HSeparator.new())
	tools.add_child(_label("SCENARIO", 13, Color("a4b2ad")))
	fixture_menu = OptionButton.new()
	for title_text: String in ["Test: iron plate", "Test: components", "Test: two furnaces", "Test: empty grid", "Contracts: empty grid", "Test: 10-power factory", "Test: maintenance"]:
		fixture_menu.add_item(title_text)
	fixture_menu.select(4)
	tools.add_child(fixture_menu)
	var load_button: Button = _button("Load scenario", 8, "Replace the current layout and progress with the selected scenario")
	load_button.pressed.connect(func() -> void: reset_dialog.popup_centered())
	tools.add_child(load_button)
	sink_toggle = CheckButton.new()
	sink_toggle.text = "Test collector"
	sink_toggle.tooltip_text = "Collect arrived products into a test counter. No orders or income."
	sink_toggle.toggled.connect(func(enabled: bool) -> void: model.test_sink_enabled = enabled)
	tools.add_child(sink_toggle)
	var stage := VBoxContainer.new()
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(stage)
	board = Board.new()
	board.cell_pressed.connect(_on_cell_pressed)
	stage.add_child(board)
	flow_label = _label("", 13, Color("b6c2bd"))
	flow_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stage.add_child(flow_label)
	message_label = _label("", 13, Color("b5c4b9"))
	message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message_label.custom_minimum_size.y = 20
	layout.add_child(message_label)
	reset_dialog = ConfirmationDialog.new()
	reset_dialog.title = "Replace factory"
	reset_dialog.dialog_text = "Discard the current layout, inventory and order progress?"
	reset_dialog.confirmed.connect(_load_fixture)
	add_child(reset_dialog)
	load_dialog = ConfirmationDialog.new()
	load_dialog.title = "Load saved factory"
	load_dialog.dialog_text = "Replace the current factory with the saved state? Unsaved changes will be lost."
	load_dialog.confirmed.connect(_load_saved)
	add_child(load_dialog)
	exit_dialog = ConfirmationDialog.new()
	exit_dialog.title = "End factory shift"
	exit_dialog.dialog_text = "Save the current factory before exiting?"
	exit_dialog.ok_button_text = "Save and exit"
	exit_dialog.dialog_hide_on_ok = false
	exit_dialog.add_button("Exit without saving", false, "discard")
	exit_dialog.confirmed.connect(_save_and_exit)
	exit_dialog.custom_action.connect(func(action: StringName) -> void:
		if action == "discard":
			_quit_game()
	)
	add_child(exit_dialog)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_instance_valid(exit_dialog):
		reset_dialog.hide()
		load_dialog.hide()
		exit_dialog.dialog_text = "Save the current factory before exiting?"
		exit_dialog.popup_centered()


func _quit_game() -> void:
	get_tree().quit()


func _save_and_exit() -> void:
	if _save_current():
		_quit_game()
	else:
		exit_dialog.dialog_text = message_label.text + "\nThe factory is still open."


func _save_current() -> bool:
	if not model.pending_commands.is_empty():
		model.step()
	running = false
	var result: Dictionary = save_store.save_game(model, save_path)
	message_label.text = "Save failed: " + str(result.error) if result.has("error") else "Saved. Simulation paused."
	feedback.cue("error" if result.has("error") else "save")
	_refresh()
	return not result.has("error")


func _load_saved() -> void:
	var result: Dictionary = save_store.load_game(save_path)
	if result.has("error"):
		message_label.text = "Load failed: " + str(result.error)
		feedback.cue("error")
		return
	model = result.model
	board.model = model
	running = false
	reported_orders = model.order_history.size()
	selected = Vector2i(-1, -1)
	sink_toggle.set_pressed_no_signal(model.test_sink_enabled)
	fixture_menu.select(4 if model.contracts_enabled else 3)
	_select_tool("inspect")
	message_label.text = "Recovered previous save from backup. Paused." if result.recovered else "Loaded saved factory. Paused."
	if result.get("migrated", false):
		message_label.text += " Version 1 migrated; original wear-free rules retained."
	feedback.cue("save")
	_refresh()


func _set_sound(enabled: bool) -> void:
	if feedback.set_sound_enabled(enabled) != OK:
		message_label.text = "Sound changed for this session; preferences could not be saved."
	if enabled:
		feedback.cue("command")
	_refresh()


func _modal_open() -> bool:
	return reset_dialog.visible or load_dialog.visible or exit_dialog.visible


func _load_fixture() -> void:
	model = Fixtures.create(MODES[fixture_menu.selected])
	running = false
	reported_orders = 0
	selected = Vector2i(-1, -1)
	board.model = model
	sink_toggle.set_pressed_no_signal(false)
	sidebar.scroll_vertical = 0
	_select_tool("source" if model.contracts_enabled else "inspect")
	message_label.text = "Contract shift started." if model.contracts_enabled else "Test fixture loaded."
	_refresh()


func _select_tool(kind: String) -> void:
	active_tool = kind
	for button_kind: String in build_buttons:
		build_buttons[button_kind].set_pressed_no_signal(button_kind == kind)
	board.tool = kind
	board._update_tooltip()
	board.queue_redraw()


func _process(delta: float) -> void:
	if model == null:
		return
	if running and not _modal_open():
		model.advance(delta)
	if model.order_history.size() > reported_orders:
		var completed: Dictionary = model.order_history.back()
		message_label.text = "%s completed. +%d credits." % [completed.id, completed.reward]
		reported_orders = model.order_history.size()
		feedback.cue("order")
	if not model.command_errors.is_empty():
		message_label.text = model.command_errors.back()
		model.command_errors.clear()
		feedback.cue("error")
	_refresh()


func _dispatch(command: Dictionary) -> void:
	if running:
		model.pending_commands.append(command.duplicate(true))
		message_label.text = "Queued for next tick."
		feedback.cue("queued")
	else:
		var error: String = model.execute_command(command)
		message_label.text = error if not error.is_empty() else "Updated."
		feedback.cue("error" if not error.is_empty() else ("repair" if command.action == "repair" else "command"))
	_refresh()


func _toggle_run() -> void:
	if running and not model.pending_commands.is_empty():
		model.step()
	running = not running
	_refresh()


func _on_cell_pressed(cell: Vector2i, mouse_button: int) -> void:
	if mouse_button not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return
	selected = cell
	if mouse_button == MOUSE_BUTTON_RIGHT:
		_select_tool("inspect")
	elif active_tool != "inspect" and not model.cells.has(cell):
		_dispatch({"action": "place", "kind": active_tool, "cell": cell, "facing": build_facing})
	_refresh()


func _rotate() -> void:
	if active_tool == "inspect" and model.cells.has(selected):
		_dispatch({"action": "rotate", "cell": selected})
	else:
		build_facing = (build_facing + 1) % 4
	_refresh()


func _remove_selected() -> void:
	_dispatch({"action": "remove", "cell": selected})


func _set_enabled(enabled: bool) -> void:
	_dispatch({"action": "enabled", "cell": selected, "enabled": enabled})


func _set_storage(index: int) -> void:
	_dispatch({"action": "storage", "cell": selected, "item": ITEMS[index]})


func conversion_state() -> Dictionary:
	if not model.contracts_enabled or model.order_index != 1:
		return {}
	if not model.pending_commands.is_empty():
		return {"stage": "queued", "text": "O2 / Pending commands", "tooltip": "The conversion state updates after queued commands execute."}
	var target: Vector2i = Factory.CATALOG.conversion.cell
	var source := Vector2i(-1, -1)
	var delivery := Vector2i(-1, -1)
	var expected_count: int = Factory.CATALOG.starter_layout.size() - (0 if model.cells.has(target) else 1)
	var matches_layout: bool = model.cells.size() == expected_count
	for entry: Dictionary in Factory.CATALOG.starter_layout:
		if entry.kind == "source":
			source = entry.cell
		elif entry.kind == "delivery":
			delivery = entry.cell
		if entry.cell == target and not model.cells.has(target):
			continue
		if not model.cells.has(entry.cell):
			matches_layout = false
			continue
		var building: Dictionary = model.cells[entry.cell]
		var valid_kind: bool = building.kind == entry.kind or (entry.cell == target and building.kind == Factory.CATALOG.conversion.kind)
		if not valid_kind or building.facing != entry.facing:
			matches_layout = false
	if not matches_layout:
		return {"stage": "custom", "text": "O2 / Custom layout", "tooltip": "Fixed-cell conversion applies only to the starter line. Your layout remains unrestricted."}
	if not model.order_active:
		return {"stage": "accept", "text": "O2 / Awaiting contract", "tooltip": "Accept O2 before counting its new plate delivery."}
	var plates_required: int = int(model.current_order().requirements.iron_plate)
	if int(model.order_progress.iron_plate) < plates_required:
		var early_press: bool = model.cells.has(target) and model.cells[target].kind == Factory.CATALOG.conversion.kind
		return {"stage": "plates", "text": "O2 / Plates %d / %d%s" % [model.order_progress.iron_plate, plates_required, " / Press already installed" if early_press else ""], "cell": delivery, "tooltip": "O2 still needs direct plate deliveries. An inline press converts plates into components." if early_press else "Locate delivery. Complete O2's plate quota before converting this line."}
	if model.cells.has(target) and model.cells[target].kind == Factory.CATALOG.conversion.kind:
		if not model.cells[source].enabled:
			return {"stage": "resume", "text": "O2 / Press installed / Supply off", "cell": source, "tooltip": "Locate the source to re-enable supply when ready."}
		return {"stage": "production", "text": "O2 / Component line installed", "cell": target, "tooltip": "Inspect the press for actual input, power, progress and output. Installation alone does not guarantee production."}
	if model.cells[source].enabled:
		return {"stage": "stop", "text": "O2 / Plate quota met / Supply on", "cell": source, "tooltip": "Locate the source and disable supply before draining this line."}
	var buffered: int = 0
	var active_batches: int = 0
	for cell: Vector2i in model.ordered_cells():
		if cell == delivery:
			continue
		var building: Dictionary = model.cells[cell]
		buffered += building.input.size() + building.output.size()
		active_batches += 1 if building.active else 0
	if buffered > 0 or active_batches > 0:
		return {"stage": "drain", "text": "O2 / Draining: %d buffered / %d active batches" % [buffered, active_batches], "cell": target, "tooltip": "Keep the source off and run the line until existing materials drain. Check disabled or blocked machines if draining stalls."}
	if model.cells.has(target):
		return {"stage": "remove", "text": "O2 / Line empty / Belt refundable", "cell": target, "tooltip": "Locate the empty belt, then remove it before placing the press."}
	var price: int = int(Factory.CATALOG.buildings[Factory.CATALOG.conversion.kind].price)
	return {"stage": "build", "text": "O2 / Press site empty / Cost %d%s" % [price, " / Insufficient funds" if model.cash < price else ""], "cell": target, "build": true, "tooltip": "Select the press tool and its target. Placement remains manual and uses the normal purchase rules."}


func _focus_conversion() -> void:
	var state: Dictionary = conversion_state()
	if not state.has("cell"):
		return
	selected = state.cell
	if state.get("build", false):
		build_facing = 0
		_select_tool(Factory.CATALOG.conversion.kind)
	else:
		_select_tool("inspect")
	_refresh()
	sidebar.ensure_control_visible(build_buttons[Factory.CATALOG.conversion.kind] if state.get("build", false) else enabled_toggle)


func _refresh() -> void:
	var conversion: Dictionary = conversion_state()
	conversion_bar.visible = not conversion.is_empty()
	if not conversion.is_empty():
		conversion_label.text = conversion.text
		conversion_label.tooltip_text = conversion.tooltip
		conversion_button.tooltip_text = conversion.tooltip
		conversion_button.disabled = not conversion.has("cell")
		conversion_button.icon = _icon(4 if conversion.get("build", false) else 7)
	plan_toggle.visible = model.contracts_enabled and model.order_index == 0
	sound_button.icon = _icon(16 if feedback.sound_enabled else 17)
	sound_button.tooltip_text = "Sound on; click to mute" if feedback.sound_enabled else "Sound muted; click to enable"
	var completed: bool = model.contracts_enabled and model.current_order().is_empty()
	if completed:
		running = false
	play_button.disabled = completed
	play_button.icon = _icon(11 if running else 10)
	load_save_button.disabled = not FileAccess.file_exists(save_path) and not FileAccess.file_exists(save_path + ".bak")
	mode_label.text = "M3  /  CONTRACTS" if model.contracts_enabled else "TEST  /  LOGISTICS"
	var plates: int = 0
	var components: int = 0
	for cell: Vector2i in model.ordered_cells():
		if model.cells[cell].kind == "delivery":
			plates += model.item_count(cell, "iron_plate")
			components += model.item_count(cell, "component")
	var power_text: String = "TEST / unlimited" if model.unlimited_power else "%d / %d (demand %d)" % [model.power_used, model.power_capacity, model.power_demand]
	stats_label.text = "%s  |  Credits %d  |  %.1f s  |  Power: %s" % ["RUNNING" if running else "PAUSED", model.cash, model.tick_count * Factory.TICK_SECONDS, power_text]
	flow_label.text = "Delivery buffer: %d plates / %d parts" % [plates, components]
	if model.contracts_enabled:
		flow_label.text += "  |  Delivered: %d plates / %d parts\nOrder rate (%.1f s): %.1f plates/min / %.1f parts/min" % [model.fulfilled.iron_plate, model.fulfilled.component, model.delivery_samples.size() * Factory.TICK_SECONDS, model.delivery_per_minute("iron_plate"), model.delivery_per_minute("component")]
	else:
		flow_label.text += "  |  Test collected: %d plates / %d parts" % [model.collected.iron_plate, model.collected.component]
	_refresh_order()
	facing_label.text = DIRECTIONS[build_facing]
	board.facing = build_facing
	board.selected = selected
	board._update_tooltip()
	var has_selection: bool = model.cells.has(selected)
	enabled_toggle.visible = has_selection
	storage_menu.visible = has_selection and model.cells[selected].kind == "storage"
	priority_menu.visible = has_selection and not model.recipe_for(model.cells[selected]).is_empty()
	repair_button.visible = priority_menu.visible and model.wear_enabled
	maintenance_label.visible = repair_button.visible
	remove_button.disabled = not has_selection
	if has_selection:
		var building: Dictionary = model.cells[selected]
		inspector.text = "%s  [%d, %d]\n%s / %s\nInput %d   Output %d\nProduced %d   Sent %d" % [building.kind.capitalize(), selected.x, selected.y, DIRECTIONS[int(building.facing)], building.status.capitalize(), building.input.size(), building.output.size(), building.produced, building.sent]
		if building.active:
			inspector.text += "\nCycle %d / %d" % [building.progress, model.recipe_for(building).ticks]
		var report: Dictionary = model.diagnostics(selected)
		inspector.text += "\nWindow %.1f s\nMade %.1f/min | Sent %.1f/min" % [report.seconds, report.produced_per_minute, report.sent_per_minute]
		if priority_menu.visible:
			priority_menu.select(int(building.priority))
			inspector.text += "\nLoad %d | Powered: %s\nNo power %.0f%% | Starved %.0f%%\nBlocked %.0f%% | Disabled %.0f%%" % [model.recipe_for(building).power, "yes" if building.powered else "no", float(report.states.get("no power", 0.0)) * 100.0, float(report.states.get("missing input", 0.0)) * 100.0, float(report.states.get("output blocked", 0.0)) * 100.0, float(report.states.get("disabled", 0.0)) * 100.0]
		if repair_button.visible:
			var wear_limit: int = int(Factory.CATALOG.maintenance.wear_limit)
			var condition: String = "50% speed" if building.wear >= wear_limit else ("Service due" if building.wear >= int(Factory.CATALOG.maintenance.warning_at) else "Good")
			maintenance_label.text = "Wear %.0f%% / %s" % [float(building.wear) * 100.0 / wear_limit, condition]
			if building.repair_remaining > 0:
				maintenance_label.text = "Maintenance: %.1f s remaining" % [building.repair_remaining * Factory.TICK_SECONDS]
			repair_button.disabled = completed or building.wear == 0 or building.repair_remaining > 0 or model.cash < int(Factory.CATALOG.maintenance.repair_cost)
			inspector.text += "\nDegraded %.0f%% | Service %.0f%%" % [float(report.states.get("degraded", 0.0)) * 100.0, float(report.states.get("maintenance", 0.0)) * 100.0]
		enabled_toggle.set_pressed_no_signal(building.enabled)
		if storage_menu.visible:
			storage_menu.select(ITEMS.find(building.storage_item))
	else:
		inspector.text = "No selection"
	board.queue_redraw()


func _refresh_order() -> void:
	sink_toggle.visible = not model.contracts_enabled
	accept_button.visible = model.contracts_enabled
	upgrade_button.visible = not model.unlimited_power
	upgrade_button.disabled = model.power_upgraded or model.cash < int(Factory.CATALOG.power.upgrade_cost)
	upgrade_button.text = "Power expanded" if model.power_upgraded else "+4 power / 240"
	var order: Dictionary = model.current_order()
	accept_button.disabled = model.order_active or order.is_empty()
	if not model.contracts_enabled:
		order_label.text = "LOGISTICS TEST BENCH"
		order_progress_label.text = "10-power fixture" if not model.unlimited_power else "Unlimited-power fixture"
	elif order.is_empty():
		order_label.text = "ALL CONTRACTS COMPLETED"
		order_progress_label.text = "3 / 3 completed | Credits %d | %.1f s simulated" % [model.cash, model.tick_count * Factory.TICK_SECONDS]
	else:
		order_label.text = "%s / %s / +%d credits" % [order.id, order.title, order.reward]
		var progress: Dictionary = model.order_progress if model.order_active else {"iron_plate": 0, "component": 0}
		order_progress_label.text = "%s | Plates %d / %d | Parts %d / %d" % ["ACTIVE" if model.order_active else "AVAILABLE", progress.iron_plate, order.requirements.iron_plate, progress.component, order.requirements.component]
		if model.order_active:
			order_progress_label.text += " | %.1f s" % [(model.tick_count - model.order_started_tick) * Factory.TICK_SECONDS]


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or _modal_open():
		return
	match event.keycode:
		KEY_SPACE:
			_toggle_run()
		KEY_R:
			_rotate()
		KEY_DELETE:
			_remove_selected()
		KEY_ESCAPE:
			_select_tool("inspect")
		KEY_F5:
			_save_current()
		KEY_F9:
			load_dialog.popup_centered()
		_:
			return
	get_viewport().set_input_as_handled()