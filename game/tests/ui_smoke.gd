extends SceneTree

const Main = preload("res://presentation/main.gd")

class TestMain extends Main:
	var exit_count: int = 0

	func _quit_game() -> void:
		exit_count += 1

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(label)


func _click_board(main: Main, cell: Vector2i, mouse_button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var position: Vector2 = main.board.global_position + main.board.cell_center(cell)
	var press := InputEventMouseButton.new()
	press.button_index = mouse_button
	press.position = position
	press.global_position = position
	press.pressed = true
	root.push_input(press)
	var release: InputEventMouseButton = press.duplicate()
	release.pressed = false
	root.push_input(release)


func _capture(main: Main, dimensions: Vector2i, filename: String) -> void:
	root.size = dimensions
	for frame: int in range(4):
		await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	expect(not image.is_empty(), "Rendered image: " + filename)
	expect(image.get_size() == dimensions, "Native-size render without scaling: " + filename)
	expect(image.get_pixel(image.get_width() / 2, image.get_height() / 2) != image.get_pixel(0, 0), "Board is not a blank background: " + filename)
	var viewport_rect := Rect2(Vector2.ZERO, root.get_visible_rect().size)
	expect(viewport_rect.encloses(main.board.get_global_rect()), "Board inside viewport: " + filename)
	expect(viewport_rect.encloses(main.sidebar.get_global_rect()), "Sidebar inside viewport: " + filename)
	expect(not main.board.get_global_rect().intersects(main.sidebar.get_global_rect()), "Board and sidebar do not overlap: " + filename)
	expect(viewport_rect.encloses(main.order_bar.get_global_rect()), "Contract controls fit viewport: " + filename)
	expect(not main.order_bar.get_global_rect().intersects(main.board.get_global_rect()), "Contract controls do not cover board: " + filename)
	if main.conversion_bar.visible:
		expect(viewport_rect.encloses(main.conversion_bar.get_global_rect()), "Conversion controls fit viewport: " + filename)
		expect(not main.conversion_bar.get_global_rect().intersects(main.board.get_global_rect()), "Conversion controls do not cover board: " + filename)
	var destination: String = ProjectSettings.globalize_path("res://../.tools/verification/" + filename)
	DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
	expect(image.save_png(destination) == OK, "Save screenshot: " + filename)
	print("Screenshot: " + destination)


func _test_conversion_states(main: Main) -> void:
	var original = main.model
	var model = main.Fixtures.create("plate")
	model.contracts_enabled = true
	model.order_index = 1
	model.order_active = true
	main.model = model
	model.order_progress.iron_plate = 12
	expect(main.conversion_state().stage == "stop", "Plate quota with active supply requests supply inspection")
	model.cells[Vector2i(2, 7)].enabled = false
	model.cells[Vector2i(6, 7)].active = true
	expect(main.conversion_state().stage == "drain", "An upstream in-progress batch blocks the empty-line stage")
	model.cells[Vector2i(6, 7)].active = false
	model.cells[Vector2i(3, 7)].output.append({"item": "iron_plate", "ready": 1})
	expect(main.conversion_state().stage == "drain", "Upstream buffer blocks conversion even when the replacement belt is empty")
	model.cells[Vector2i(3, 7)].output.clear()
	model.cells[Vector2i(18, 7)].output.append({"item": "iron_plate", "ready": 1})
	expect(main.conversion_state().stage == "remove", "Delivered surplus does not prevent draining the production line")
	model.pending_commands.append({"action": "enabled", "cell": Vector2i(2, 7), "enabled": true})
	expect(main.conversion_state().stage == "queued" and not main.conversion_state().has("cell"), "Pending commands suppress stale conversion targets")
	model.pending_commands.clear()
	model.place("belt", Vector2i.ZERO)
	expect(main.conversion_state().stage == "custom" and not main.conversion_state().has("cell"), "Extra buildings suppress fixed-layout instructions")
	model.remove(Vector2i.ZERO)
	model.rotate(Vector2i(5, 7))
	expect(main.conversion_state().stage == "custom", "Rotated belt prevents claiming the reference line is intact")
	model.cells[Vector2i(5, 7)].facing = 0
	model.remove(Vector2i(5, 7))
	expect(main.conversion_state().stage == "custom", "Missing non-conversion segment is a custom layout")
	model.place("belt", Vector2i(5, 7))
	model.remove(Vector2i(12, 7))
	model.place("press", Vector2i(12, 7))
	model.order_progress.iron_plate = 0
	expect(main.conversion_state().stage == "plates" and main.conversion_state().text.contains("already installed"), "Early press never skips unmet plate delivery")
	model.order_progress.iron_plate = 12
	model.remove(Vector2i(12, 7))
	model.cash = 179
	expect(main.conversion_state().stage == "build" and main.conversion_state().text.contains("Insufficient funds"), "Unaffordable press is disclosed without granting funds")
	var unchanged: Dictionary = model.snapshot()
	main.conversion_state()
	expect(model.snapshot() == unchanged, "Conversion state calculation is read-only")
	main.model = original


func _run() -> void:
	root.size = Vector2i(1280, 800)
	var main := TestMain.new()
	var save_prefix: String = "user://tests/ui-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	main.save_path = save_prefix + "/slot.json"
	main.settings_path = save_prefix + "/preferences.cfg"
	root.add_child(main)
	for frame: int in range(4):
		await process_frame
	expect(main.model.cells.is_empty() and main.model.contracts_enabled and not main.running, "Scene starts with paused empty contract factory")
	_test_conversion_states(main)
	expect(not main.sink_toggle.visible and main.accept_button.visible, "Contract controls exclude test collector")
	var empty_factory: Dictionary = main.model.snapshot()
	expect(main.board.visible_plan().size() == 17 and main.plan_toggle.visible, "New contract exposes optional first-order layout")
	main.plan_toggle.button_pressed = false
	expect(main.board.visible_plan().is_empty() and main.model.snapshot() == empty_factory, "Hiding the starter layout changes no factory state")
	main.plan_toggle.button_pressed = true
	expect(main.model.snapshot() == empty_factory and main.model.cash == 800, "Showing layout does not build or spend credits")
	await _capture(main, Vector2i(1280, 800), "m3-starter-desktop.png")
	await _capture(main, Vector2i(960, 640), "m3-starter-compact.png")
	root.size = Vector2i(1280, 800)
	for frame: int in range(4):
		await process_frame
	main.board.hovered = Vector2i(3, 7)
	main._refresh()
	expect(main.board.tooltip_text.contains("Source requires the inlet"), "Empty-cell preview explains invalid source location")
	main.board.hovered = Vector2i(2, 7)
	main._refresh()
	expect(main.board.tooltip_text.contains("60 credits") and not main.board.tooltip_text.contains("requires"), "Valid inlet preview displays source price")
	main.build_buttons.smelter.pressed.emit()
	main.rotate_button.pressed.emit()
	expect(main.board.tooltip_text.contains("South"), "Stationary hover refreshes after tool rotation")
	var before_ports: Dictionary = main.model.snapshot()
	for direction: int in range(4):
		var furnace: Dictionary = {"kind": "smelter", "facing": direction}
		expect(main.model.input_items(furnace, (direction + 2) % 4) == ["iron_ore"] and main.model.input_items(furnace, direction).is_empty(), "Rotated furnace exposes only its true ingredient inlet")
		var splitter: Dictionary = {"kind": "splitter", "facing": direction}
		expect(main.model.output_sides(splitter) == [direction, (direction + 1) % 4], "Splitter preview follows real forward/right outlets")
		var belt: Dictionary = {"kind": "belt", "facing": direction}
		expect(main.model.input_items(belt, direction).is_empty() and main.model.input_items(belt, (direction + 1) % 4).size() == 3, "Belt preview preserves side-loading rules")
	expect(main.model.input_items({"kind": "storage", "facing": 0, "storage_item": "component"}, 2) == ["component"], "Storage preview respects its selected item")
	expect(main.model.output_sides({"kind": "delivery", "facing": 0}).is_empty(), "Delivery has no misleading outlet")
	expect(main.model.snapshot() == before_ports, "Port queries never mutate the factory")
	main.build_facing = 0
	main.build_buttons.source.pressed.emit()
	main.board.hovered = Vector2i(-1, -1)
	main._refresh()
	for cue: String in main.feedback.clips:
		var clip: AudioStreamWAV = main.feedback.clips[cue]
		var peak: int = 0
		for offset: int in range(0, clip.data.size(), 2):
			peak = maxi(peak, absi(clip.data.decode_s16(offset)))
		expect(clip.get_length() > 0.0 and peak > 0 and peak <= 12000 and clip.data.decode_s16(0) == 0 and clip.data.decode_s16(clip.data.size() - 2) == 0, "Audio cue has bounded nonzero PCM with silent boundaries: " + cue)
	var before_audio: Dictionary = main.model.snapshot()
	main.feedback.cue("command")
	expect(main.feedback.playing and main.model.snapshot() == before_audio, "Feedback starts playback without touching simulation")
	main.sound_button.button_pressed = false
	expect(not main.feedback.playing and not main.feedback.cue("order") and not main.feedback.sound_enabled, "Mute stops active sound and suppresses future cues")
	var preferences = main.Feedback.new()
	preferences.settings_path = main.settings_path
	root.add_child(preferences)
	expect(not preferences.sound_enabled and preferences.settings_error == OK, "Mute preference survives a new audio instance")
	preferences.queue_free()
	main.sound_button.button_pressed = true
	main.accept_button.pressed.emit()
	expect(main.feedback.stream == main.feedback.clips.command, "Successful paused command selects confirmation cue")
	expect(main.model.order_active and main.accept_button.disabled, "Accept button starts O1 and prevents repeat acceptance")
	main.play_button.pressed.emit()
	var modal_tick: int = main.model.tick_count
	main.reset_dialog.popup_centered()
	main._process(0.2)
	expect(main.model.tick_count == modal_tick, "Confirmation dialog freezes simulation")
	main.reset_dialog.hide()
	main._process(0.1)
	expect(main.model.tick_count > modal_tick, "Cancelling confirmation resumes prior running state")
	main.play_button.pressed.emit()
	main.fixture_menu.select(3)
	main.reset_dialog.confirmed.emit()
	expect(main.model.cells.is_empty(), "Load empty fixture")
	expect(main.board.visible_plan().is_empty() and not main.plan_toggle.visible, "Test scenarios never display contract layout")
	main.build_buttons.belt.pressed.emit()
	_click_board(main, Vector2i(5, 5))
	expect(main.model.cells.has(Vector2i(5, 5)) and main.model.cash == 795, "Mouse placement routes through board")
	_click_board(main, Vector2i(5, 5), MOUSE_BUTTON_RIGHT)
	expect(main.active_tool == "inspect", "Right click enters inspection")
	expect(main.build_buttons.inspect.button_pressed and not main.build_buttons.belt.button_pressed, "Exactly one tool is highlighted")
	main.rotate_button.pressed.emit()
	expect(main.model.cells[Vector2i(5, 5)].facing == 1, "Rotate inspected building")
	main.remove_button.pressed.emit()
	expect(main.model.cells.is_empty() and main.model.cash == 800, "Remove selected empty building")
	main.play_button.pressed.emit()
	expect(main.running, "Play control starts clock")
	main.play_button.pressed.emit()
	expect(not main.running, "Pause control stops clock")
	main.fixture_menu.select(2)
	main.reset_dialog.confirmed.emit()
	main.sink_toggle.button_pressed = true
	expect(main.model.test_sink_enabled, "Collector toggle is connected")
	main.model.advance(120.0)
	_click_board(main, Vector2i(12, 7), MOUSE_BUTTON_RIGHT)
	main._refresh()
	expect(main.model.collected.component > 20, "Visible fixture processes components")
	main.fixture_menu.select(5)
	main.reset_dialog.confirmed.emit()
	main.sink_toggle.button_pressed = true
	main.model.advance(60.0)
	_click_board(main, Vector2i(12, 7), MOUSE_BUTTON_RIGHT)
	main.priority_menu.select(0)
	main.priority_menu.item_selected.emit(0)
	expect(main.model.cells[Vector2i(12, 7)].priority == 0, "Priority menu changes machine arbitration")
	main.model.advance(30.0)
	main._refresh()
	expect(main.upgrade_button.visible and not main.upgrade_button.disabled, "Finite-power fixture offers affordable expansion")
	await _capture(main, Vector2i(1280, 800), "m3-power.png")
	main.upgrade_button.pressed.emit()
	expect(main.model.power_capacity == 14 and main.model.cash == 40 and main.upgrade_button.disabled, "Expansion button charges once and disables")
	main.fixture_menu.select(4)
	main.reset_dialog.confirmed.emit()
	main.accept_button.pressed.emit()
	for frame: int in range(4):
		await process_frame
	for entry: Dictionary in main.Factory.CATALOG.starter_layout:
		main.build_buttons[entry.kind].pressed.emit()
		main.build_facing = entry.facing
		main._refresh()
		_click_board(main, entry.cell)
	expect(main.model.cells.size() == 17 and main.model.cash == 470 and main.board.visible_plan().is_empty(), "Mouse-built starter layout charges full 330 cost and replaces every ghost")
	main.model.advance(45.0)
	main._process(0.0)
	expect(main.feedback.stream == main.feedback.clips.order, "Order settlement selects completion cue")
	main._refresh()
	expect(main.model.order_index == 1 and not main.accept_button.disabled, "Completed O1 unlocks O2 in UI")
	expect(not main.plan_toggle.visible and main.board.visible_plan().is_empty(), "O1 completion retires the layout without affecting O2")
	expect(main.conversion_state().stage == "accept" and main.conversion_button.disabled, "O2 conversion waits for accepting the new contract")
	main.accept_button.pressed.emit()
	expect(main.conversion_state().stage == "plates", "O2 conversion does not confuse prior O1 plates with the new quota")
	var before_focus: Dictionary = main.model.snapshot()
	main.conversion_button.pressed.emit()
	expect(main.selected == Vector2i(18, 7) and main.model.snapshot() == before_focus, "Conversion locator selects delivery without mutating the factory")
	main._dispatch({"action": "enabled", "cell": Vector2i(2, 7), "enabled": false})
	main.model.advance(40.0)
	main._refresh()
	expect(main.conversion_state().stage == "remove", "Empty starter line exposes the refundable belt only after the plate quota")
	main.save_button.pressed.emit()
	main.load_dialog.confirmed.emit()
	expect(main.conversion_state().stage == "remove" and not main.running, "Mid-conversion save/load derives the same safe replacement stage")
	await _capture(main, Vector2i(1280, 800), "m3-conversion-desktop.png")
	await _capture(main, Vector2i(960, 640), "m3-conversion-compact.png")
	root.size = Vector2i(1280, 800)
	for frame: int in range(4):
		await process_frame
	main.conversion_button.pressed.emit()
	expect(main.selected == Vector2i(12, 7) and main.active_tool == "inspect", "Conversion locator targets the replacement belt")
	main.remove_button.pressed.emit()
	expect(main.conversion_state().stage == "build" and main.model.cash == 675, "Normal belt removal refunds five before the press purchase")
	main.conversion_button.pressed.emit()
	expect(main.active_tool == "press" and main.build_facing == 0 and main.model.cash == 675, "Press locator selects the tool but does not buy equipment")
	for frame: int in range(4):
		await process_frame
	_click_board(main, Vector2i(12, 7))
	expect(main.conversion_state().stage == "resume" and main.model.cash == 495, "Mouse purchase charges full press cost and retains supply off")
	main.conversion_button.pressed.emit()
	main.enabled_toggle.button_pressed = true
	expect(main.conversion_state().stage == "production" and main.model.cells[Vector2i(2, 7)].enabled, "Player resumes supply using the existing source control")
	main.model.advance(20.0)
	_click_board(main, Vector2i(12, 7), MOUSE_BUTTON_RIGHT)
	main._refresh()
	expect(main.model.order_active and main.model.order_progress.iron_plate == 12 and main.model.order_progress.component > 0, "O2 UI shows actual shared-resource production")
	expect(main.inspector.text.contains("No power") and main.flow_label.text.contains("Order rate"), "Inspector and delivery metrics stay distinct")
	main.save_button.pressed.emit()
	var saved_state: Dictionary = main.model.snapshot()
	expect(main.feedback.stream == main.feedback.clips.save, "Successful save selects save cue")
	expect(FileAccess.file_exists(main.save_path) and not main.running, "Save button writes isolated slot and pauses")
	main.model.advance(2.0)
	main.play_button.pressed.emit()
	main.load_save_button.pressed.emit()
	var load_modal_tick: int = main.model.tick_count
	main._process(0.2)
	expect(main.model.tick_count == load_modal_tick, "Load confirmation freezes simulation")
	main.load_dialog.hide()
	expect(main.model.tick_count != int(saved_state.tick), "Cancelling load keeps current factory")
	main.load_dialog.confirmed.emit()
	expect(main.model.snapshot() == saved_state and not main.running, "Confirmed load restores exact state and pauses")
	expect(main.conversion_state().stage == "production", "Loaded component line derives its current conversion status")
	main.model.advance(2.0)
	main.save_button.pressed.emit()
	var corrupt := FileAccess.open(main.save_path, FileAccess.WRITE)
	corrupt.store_string("{broken")
	corrupt.close()
	main.load_dialog.confirmed.emit()
	expect(main.model.snapshot() == saved_state and main.message_label.text.contains("backup"), "UI reports verified backup recovery")
	corrupt = FileAccess.open(main.save_path + ".bak", FileAccess.WRITE)
	corrupt.store_string("{broken")
	corrupt.close()
	var unchanged = main.model
	main.load_dialog.confirmed.emit()
	expect(main.model == unchanged and main.model.snapshot() == saved_state, "Failed load leaves current factory untouched")
	expect(main.feedback.stream == main.feedback.clips.error, "Failed load selects error cue")
	_click_board(main, Vector2i(12, 7), MOUSE_BUTTON_RIGHT)
	main._refresh()
	await _capture(main, Vector2i(1280, 800), "m3-desktop.png")
	await _capture(main, Vector2i(960, 640), "m3-compact.png")
	main.model.advance(80.0)
	main._refresh()
	expect(main.model.order_index == 2 and not main.accept_button.disabled, "O2 completion offers the final contract")
	expect(main.conversion_state().is_empty() and not main.conversion_bar.visible, "O2 conversion assistance retires on O3")
	main.accept_button.pressed.emit()
	main.play_button.pressed.emit()
	for tick: int in range(4000):
		if not main.running:
			break
		main._process(0.1)
	expect(main.model.order_index == 3 and not main.running and main.play_button.disabled, "Final contract automatically pauses the simulation")
	expect(main.order_label.text == "ALL CONTRACTS COMPLETED" and main.accept_button.disabled, "Final settlement prevents accepting another contract")
	expect(main.model.cash == 1155, "Unexpanded UI route settles its own correct budget")
	main.fixture_menu.select(6)
	main.reset_dialog.confirmed.emit()
	main.sink_toggle.button_pressed = true
	main.model.advance(30.0)
	_click_board(main, Vector2i(6, 7), MOUSE_BUTTON_RIGHT)
	main._refresh()
	expect(main.repair_button.visible and not main.repair_button.disabled and main.maintenance_label.text.contains("50%"), "Worn fixture offers maintenance with visible degradation")
	main.repair_button.pressed.emit()
	expect(main.feedback.stream == main.feedback.clips.repair, "Maintenance request selects service cue")
	main.model.advance(5.0)
	main._refresh()
	expect(main.model.cash == 240 and main.repair_button.disabled and main.maintenance_label.text.contains("5.0"), "Repair charges once and exposes remaining downtime")
	main.save_button.pressed.emit()
	var repair_state: Dictionary = main.model.snapshot()
	main.model.advance(1.0)
	main.load_dialog.confirmed.emit()
	expect(main.model.snapshot() == repair_state, "UI save/load preserves mid-repair state")
	_click_board(main, Vector2i(6, 7), MOUSE_BUTTON_RIGHT)
	main._refresh()
	for frame: int in range(3):
		await process_frame
	main.sidebar.ensure_control_visible(main.repair_button)
	await _capture(main, Vector2i(1280, 800), "m3-maintenance.png")
	main.model.advance(5.0)
	main._refresh()
	expect(main.model.cells[Vector2i(6, 7)].wear == 0 and main.model.cells[Vector2i(6, 7)].repair_remaining == 0 and main.model.cash == 240, "Loaded repair completes without a second charge")
	main.play_button.pressed.emit()
	root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	var exit_tick: int = main.model.tick_count
	main._process(0.3)
	expect(not auto_accept_quit and main.exit_dialog.visible and main.model.tick_count == exit_tick and main.exit_count == 0, "Window close asks before exiting and freezes simulation")
	main.exit_dialog.get_cancel_button().pressed.emit()
	await process_frame
	main._process(0.1)
	expect(not main.exit_dialog.visible and main.running and main.model.tick_count > exit_tick, "Cancel exit resumes the running factory (visible=%s, running=%s, tick=%d, before=%d)" % [main.exit_dialog.visible, main.running, main.model.tick_count, exit_tick])
	root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	main.exit_dialog.custom_action.emit("discard")
	expect(main.exit_count == 1, "Explicit discard requests exit without saving")
	var discarded_save: Dictionary = main.save_store.load_game(main.save_path)
	expect(not discarded_save.has("error") and discarded_save.model.snapshot() == repair_state, "Exit without saving leaves the previous save untouched")
	var blocked := FileAccess.open(save_prefix + "/blocked", FileAccess.WRITE)
	blocked.store_string("not a directory")
	blocked.close()
	var before_preferences: Dictionary = main.model.snapshot()
	main.feedback.settings_path = save_prefix + "/blocked/preferences.cfg"
	main.sound_button.button_pressed = false
	expect(not main.feedback.sound_enabled and main.message_label.text.contains("could not be saved") and main.model.snapshot() == before_preferences, "Preference write failure retains session mute without altering the factory")
	main.feedback.settings_path = main.settings_path
	main.sound_button.button_pressed = true
	main.save_path = save_prefix + "/blocked/slot.json"
	main.exit_dialog.confirmed.emit()
	expect(main.exit_count == 1 and main.exit_dialog.visible and main.exit_dialog.dialog_text.contains("Save failed"), "Failed save cannot exit or hide the recovery choice")
	main.save_path = save_prefix + "/slot.json"
	main.exit_dialog.get_cancel_button().pressed.emit()
	await process_frame
	main.play_button.pressed.emit()
	main._dispatch({"action": "enabled", "cell": Vector2i(2, 7), "enabled": false})
	expect(main.model.pending_commands.size() == 1 and main.feedback.stream == main.feedback.clips.queued, "Running command remains queued with a distinct acknowledgement cue")
	root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	main.exit_dialog.confirmed.emit()
	var exit_save: Dictionary = main.save_store.load_game(main.save_path)
	expect(main.exit_count == 2 and not exit_save.has("error") and exit_save.model.snapshot() == main.model.snapshot(), "Save and exit persists the final factory before requesting exit")
	expect(main.model.pending_commands.is_empty() and not exit_save.model.cells[Vector2i(2, 7)].enabled, "Exit save commits pending commands before writing")
	main.exit_dialog.hide()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_prefix + "/blocked"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(main.settings_path))
	for filename: String in [main.save_path, main.save_path + ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(filename))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_prefix))
	print("Factory UI smoke: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)