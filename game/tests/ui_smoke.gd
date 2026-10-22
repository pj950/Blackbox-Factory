extends SceneTree

const Main = preload("res://presentation/main.gd")

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
	var destination: String = ProjectSettings.globalize_path("res://../.tools/verification/" + filename)
	DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
	expect(image.save_png(destination) == OK, "Save screenshot: " + filename)
	print("Screenshot: " + destination)


func _run() -> void:
	root.size = Vector2i(1280, 800)
	var main := Main.new()
	var save_prefix: String = "user://tests/ui-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	main.save_path = save_prefix + "/slot.json"
	root.add_child(main)
	for frame: int in range(4):
		await process_frame
	expect(main.model.cells.is_empty() and main.model.contracts_enabled and not main.running, "Scene starts with paused empty contract factory")
	expect(not main.sink_toggle.visible and main.accept_button.visible, "Contract controls exclude test collector")
	main.accept_button.pressed.emit()
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
	for entry: Array in [["source", 2], ["smelter", 6], ["delivery", 18]]:
		main._dispatch({"action": "place", "kind": entry[0], "cell": Vector2i(entry[1], 7)})
	for column: int in range(3, 18):
		if column != 6:
			main._dispatch({"action": "place", "kind": "belt", "cell": Vector2i(column, 7)})
	main.model.advance(45.0)
	main._refresh()
	expect(main.model.order_index == 1 and not main.accept_button.disabled, "Completed O1 unlocks O2 in UI")
	main.accept_button.pressed.emit()
	main._dispatch({"action": "enabled", "cell": Vector2i(2, 7), "enabled": false})
	main.model.advance(40.0)
	main._dispatch({"action": "remove", "cell": Vector2i(12, 7)})
	main._dispatch({"action": "place", "kind": "press", "cell": Vector2i(12, 7)})
	main._dispatch({"action": "enabled", "cell": Vector2i(2, 7), "enabled": true})
	main.model.advance(20.0)
	_click_board(main, Vector2i(12, 7), MOUSE_BUTTON_RIGHT)
	main._refresh()
	expect(main.model.order_active and main.model.order_progress.iron_plate == 12 and main.model.order_progress.component > 0, "O2 UI shows actual shared-resource production")
	expect(main.inspector.text.contains("No power") and main.flow_label.text.contains("Order rate"), "Inspector and delivery metrics stay distinct")
	main.save_button.pressed.emit()
	var saved_state: Dictionary = main.model.snapshot()
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
	_click_board(main, Vector2i(12, 7), MOUSE_BUTTON_RIGHT)
	main._refresh()
	await _capture(main, Vector2i(1280, 800), "m3-desktop.png")
	await _capture(main, Vector2i(960, 640), "m3-compact.png")
	main.model.advance(80.0)
	main._refresh()
	expect(main.model.order_index == 2 and not main.accept_button.disabled, "O2 completion offers the final contract")
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
	for filename: String in [main.save_path, main.save_path + ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(filename))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_prefix))
	print("Factory UI smoke: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)