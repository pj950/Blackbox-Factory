extends RefCounted

const Factory = preload("res://simulation/factory.gd")
const VERSION: int = 2
const MAX_BYTES: int = 16777216
const FIELDS: Dictionary = {
	"tick": "tick_count", "cash": "cash", "supplied": "supplied", "collected": "collected",
	"sink": "test_sink_enabled", "pending": "pending_commands", "errors": "command_errors",
	"contracts": "contracts_enabled", "order_index": "order_index", "order_active": "order_active",
	"order_progress": "order_progress", "fulfilled": "fulfilled", "order_history": "order_history",
	"order_started": "order_started_tick", "unlimited_power": "unlimited_power", "capacity": "power_capacity",
	"upgraded": "power_upgraded", "power_used": "power_used", "power_demand": "power_demand",
	"power_cursors": "power_cursors", "delivery_samples": "delivery_samples",
	"wear_enabled": "wear_enabled", "retired_machines": "retired_machines",
}
const STATES: Array[String] = ["idle", "disabled", "no power", "processing", "missing input", "output blocked", "ready", "receiving", "transporting", "degraded", "maintenance"]

var validation_error: String = ""


func encode(model: Factory) -> Dictionary:
	if not model.pending_commands.is_empty():
		return {"error": "Save requires a committed simulation boundary"}
	var state: Dictionary = model.snapshot()
	state.erase("recent_delivery")
	for entry: Dictionary in state.buildings:
		entry.cell = [entry.cell.x, entry.cell.y]
		for key: String in ["recent_produced", "recent_sent", "status_counts"]:
			entry.state.erase(key)
	var payload: String = JSON.stringify({"simulation": state, "accumulator": model.accumulator}, "", true, true)
	var document: String = JSON.stringify({"format": "blackbox-factory", "version": VERSION, "payload": payload, "sha256": payload.sha256_text()})
	var verified: Dictionary = decode(document)
	if verified.has("error"):
		return verified
	return {"document": document}


func decode(document: String) -> Dictionary:
	validation_error = ""
	if document.to_utf8_buffer().size() > MAX_BYTES:
		return {"error": "Save exceeds size limit"}
	var parser := JSON.new()
	if parser.parse(document) != OK or not parser.data is Dictionary:
		return {"error": "Invalid save JSON"}
	var envelope: Dictionary = parser.data
	if envelope.get("format") != "blackbox-factory" or not _integer(envelope.get("version")):
		return {"error": "Unrecognized save format"}
	if int(envelope.version) not in [1, VERSION]:
		return {"error": "Unsupported save version", "unsupported": true}
	if not envelope.get("payload") is String or not envelope.get("sha256") is String:
		return {"error": "Missing save payload or checksum"}
	if envelope.payload.sha256_text() != envelope.sha256:
		return {"error": "Save checksum mismatch"}
	if parser.parse(envelope.payload) != OK:
		return {"error": "Invalid payload JSON"}
	if int(envelope.version) == 1:
		var legacy: Variant = parser.data
		if not legacy is Dictionary or not legacy.get("simulation") is Dictionary or not legacy.simulation.get("buildings") is Array:
			return {"error": "Malformed version 1 save"}
		legacy.simulation.wear_enabled = false
		legacy.simulation.retired_machines = {"smelter": [], "press": []}
		for entry: Variant in legacy.simulation.buildings:
			if not entry is Dictionary or not entry.get("state") is Dictionary:
				return {"error": "Malformed version 1 building"}
			entry.state.wear = 0
			entry.state.wear_phase = 0
			entry.state.repair_remaining = 0
	var normalized: Variant = _normalize(parser.data, _schema())
	if not validation_error.is_empty():
		return {"error": validation_error}
	var state: Dictionary = normalized.simulation
	if float(normalized.accumulator) >= Factory.TICK_SECONDS or state.buildings.size() > Factory.WIDTH * Factory.HEIGHT:
		return {"error": "Invalid clock or building count"}
	var model = Factory.new()
	for key: String in FIELDS:
		if key == "power_cursors":
			model.power_cursors.assign(state[key])
		elif key == "errors":
			model.command_errors.assign(state[key])
		else:
			model.set(FIELDS[key], state[key])
	model.accumulator = float(normalized.accumulator)
	if model.power_cursors.size() != 3 or model.delivery_samples.size() > mini(300, model.tick_count):
		return {"error": "Invalid diagnostic history or power cursors"}
	for cursor: int in model.power_cursors:
		if cursor >= Factory.WIDTH * Factory.HEIGHT:
			return {"error": "Power cursor outside grid"}
	var source_count: int = 0
	var delivery_count: int = 0
	for entry: Dictionary in state.buildings:
		if entry.cell.size() != 2:
			return {"error": "Invalid building coordinate"}
		var cell := Vector2i(entry.cell[0], entry.cell[1])
		if cell.x >= Factory.WIDTH or cell.y >= Factory.HEIGHT or model.cells.has(cell):
			return {"error": "Overlapping or out-of-bounds building"}
		var building: Dictionary = entry.state
		var error: String = _validate_building(building, model.tick_count)
		if not error.is_empty():
			return {"error": error}
		if building.kind == "source":
			source_count += 1
			if cell != Vector2i(2, 7):
				return {"error": "Source is not at its inlet"}
		if building.kind == "delivery":
			delivery_count += 1
		building.recent_produced = 0
		building.recent_sent = 0
		building.status_counts = {}
		for sample: Dictionary in building.samples:
			building.recent_produced += int(sample.produced)
			building.recent_sent += int(sample.sent)
			building.status_counts[sample.status] = int(building.status_counts.get(sample.status, 0)) + 1
		if building.recent_produced > building.produced or building.recent_sent > building.sent:
			return {"error": "Diagnostic totals exceed lifetime counts"}
		model.cells[cell] = building
	var retired_count: int = 0
	for kind: String in model.retired_machines:
		var live_count: int = 0
		for building: Dictionary in model.cells.values():
			if building.kind == kind:
				live_count += 1
		if live_count + model.retired_machines[kind].size() > Factory.WIDTH * Factory.HEIGHT:
			return {"error": "Excessive retired machine state"}
		for condition: Dictionary in model.retired_machines[kind]:
			retired_count += 1
			if condition.wear > int(Factory.CATALOG.maintenance.wear_limit) or condition.wear_phase > 1 or (condition.wear < int(Factory.CATALOG.maintenance.wear_limit) and condition.wear_phase != 0):
				return {"error": "Invalid retired machine condition"}
	if not model.wear_enabled:
		if retired_count > 0:
			return {"error": "Disabled maintenance has retired equipment"}
		for building: Dictionary in model.cells.values():
			if building.wear != 0 or building.wear_phase != 0 or building.repair_remaining != 0:
				return {"error": "Disabled maintenance contains wear"}
	if source_count > 1 or delivery_count > 1:
		return {"error": "Duplicate unique building"}
	for sample: Dictionary in model.delivery_samples:
		for item: String in model.recent_delivery:
			model.recent_delivery[item] += int(sample[item])
			if model.recent_delivery[item] > model.fulfilled[item]:
				return {"error": "Delivery history exceeds fulfilled quantities"}
	var order_error: String = _validate_orders(model)
	if not order_error.is_empty():
		return {"error": order_error}
	if model.ore_equivalent() != model.supplied:
		return {"error": "Material conservation check failed"}
	return {"model": model, "recovered": false, "migrated": int(envelope.version) != VERSION}


func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= 2147483647.0 and float(value) == floorf(float(value))


func _normalize(value: Variant, schema: Variant, depth: int = 0) -> Variant:
	if not validation_error.is_empty():
		return null
	if depth > 16:
		validation_error = "Save nesting limit exceeded"
	elif schema is Dictionary:
		if not value is Dictionary or value.size() != schema.size():
			validation_error = "Save fields do not match schema"
		else:
			var result: Dictionary = {}
			for key: String in schema:
				if not value.has(key):
					validation_error = "Missing field: " + key
					return null
				result[key] = _normalize(value[key], schema[key], depth + 1)
			return result
	elif schema is Array:
		if not value is Array or value.size() > 384 or (schema.is_empty() and not value.is_empty()):
			validation_error = "Invalid saved array"
		else:
			var result: Array = []
			for entry: Variant in value:
				result.append(_normalize(entry, schema[0], depth + 1))
			return result
	elif schema is bool:
		if value is bool:
			return value
		validation_error = "Expected boolean"
	elif schema is int:
		if _integer(value):
			return int(value)
		validation_error = "Expected nonnegative integer"
	elif schema is float:
		if (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0:
			return float(value)
		validation_error = "Expected finite clock value"
	elif schema is String:
		if value is String and value.length() <= 512:
			return value
		validation_error = "Expected bounded text"
	return null


func _schema() -> Dictionary:
	var sample = Factory.new()
	var state: Dictionary = sample.snapshot()
	state.erase("recent_delivery")
	sample.place("belt", Vector2i.ZERO)
	var building: Dictionary = sample.cells[Vector2i.ZERO].duplicate(true)
	for key: String in ["recent_produced", "recent_sent", "status_counts"]:
		building.erase(key)
	building.input = [{"item": "", "ready": 0}]
	building.output = [{"item": "", "ready": 0}]
	building.samples = [{"produced": 0, "sent": 0, "status": ""}]
	state.buildings = [{"cell": [0], "state": building}]
	state.errors = [""]
	state.power_cursors = [0]
	state.order_history = [{"id": "", "reward": 0, "elapsed_ticks": 0, "completed_tick": 0}]
	state.delivery_samples = [{"iron_plate": 0, "component": 0}]
	state.retired_machines = {"smelter": [{"wear": 0, "wear_phase": 0}], "press": [{"wear": 0, "wear_phase": 0}]}
	return {"simulation": state, "accumulator": 0.0}


func _validate_building(building: Dictionary, tick: int) -> String:
	if not Factory.CATALOG.buildings.has(building.kind) or building.facing > 3 or building.priority > 2 or building.merge_cursor > 3 or building.split_cursor > 1:
		return "Invalid building ID, direction or priority"
	if building.status not in STATES or building.work_state not in STATES or building.storage_item not in ["iron_ore", "iron_plate", "component"]:
		return "Invalid building state or item"
	if building.samples.size() > mini(300, tick):
		return "Oversized building diagnostic history"
	for sample: Dictionary in building.samples:
		if sample.status not in STATES or sample.produced > 1 or sample.sent > 1:
			return "Invalid diagnostic sample"
	var definition: Dictionary = Factory.CATALOG.buildings[building.kind]
	var recipe: Dictionary = Factory.CATALOG.recipes[definition.recipe] if definition.has("recipe") else {}
	var wear_limit: int = int(Factory.CATALOG.maintenance.wear_limit)
	if building.wear > wear_limit or building.wear_phase > 1 or building.repair_remaining > int(Factory.CATALOG.maintenance.repair_ticks) or (building.wear < wear_limit and building.wear_phase != 0):
		return "Invalid wear or maintenance progress"
	if recipe.is_empty() and (building.wear != 0 or building.wear_phase != 0 or building.repair_remaining != 0):
		return "Non-machine contains maintenance state"
	if recipe.is_empty() and (building.active or building.progress != 0 or not building.input.is_empty()):
		return "Non-machine contains a processing batch"
	if not building.active and building.progress != 0:
		return "Inactive machine has unfinished progress"
	if not recipe.is_empty() and (building.progress >= recipe.ticks or building.input.size() > int(definition.capacity) or building.output.size() + (int(recipe.output_count) if building.active else 0) > int(definition.capacity)):
		return "Invalid machine buffer or reserved output"
	for packet: Dictionary in building.input:
		if packet.item != recipe.input:
			return "Unexpected machine ingredient"
	var item_counts: Dictionary = {}
	for packet: Dictionary in building.output:
		if packet.item not in ["iron_ore", "iron_plate", "component"]:
			return "Unknown saved item"
		if not recipe.is_empty() and packet.item != recipe.output:
			return "Unexpected machine output"
		if building.kind == "source" and packet.item != "iron_ore":
			return "Unexpected source item"
		if building.kind == "storage" and packet.item != building.storage_item:
			return "Mixed warehouse contents"
		if building.kind == "delivery" and packet.item == "iron_ore":
			return "Delivery cannot contain ore"
		item_counts[packet.item] = int(item_counts.get(packet.item, 0)) + 1
	if building.kind == "delivery":
		for count: int in item_counts.values():
			if count > int(definition.capacity):
				return "Delivery buffer overflow"
	elif building.output.size() > int(definition.capacity):
		return "Output buffer overflow"
	return ""


func _validate_orders(model: Factory) -> String:
	var orders: Array = Factory.CATALOG.orders
	if model.order_index > orders.size() or model.order_history.size() != model.order_index or (model.order_active and model.order_index >= orders.size()) or model.order_started_tick > model.tick_count:
		return "Invalid order progression"
	var totals: Dictionary = {"iron_plate": 0, "component": 0}
	var last_completed: int = 0
	for index: int in range(model.order_history.size()):
		var record: Dictionary = model.order_history[index]
		if record.id != orders[index].id or record.reward != orders[index].reward or record.completed_tick < last_completed or record.completed_tick > model.tick_count or record.elapsed_ticks > record.completed_tick:
			return "Invalid completed order record"
		last_completed = record.completed_tick
		for item: String in totals:
			totals[item] += int(orders[index].requirements[item])
	var requirement: Dictionary = orders[model.order_index].requirements if model.order_active else (orders[model.order_index - 1].requirements if model.order_index > 0 else {"iron_plate": 0, "component": 0})
	for item: String in totals:
		if model.order_progress[item] > requirement[item] or (not model.order_active and model.order_progress[item] != requirement[item]):
			return "Order progress does not match requirements"
		if model.order_active:
			totals[item] += int(model.order_progress[item])
		if totals[item] != model.fulfilled[item]:
			return "Fulfilled inventory does not match order history"
	if model.contracts_enabled and (model.unlimited_power or model.test_sink_enabled or model.collected.iron_plate != 0 or model.collected.component != 0):
		return "Contract contains test-only state"
	if not model.contracts_enabled and (model.order_index != 0 or model.order_active or model.fulfilled.iron_plate != 0 or model.fulfilled.component != 0):
		return "Test fixture contains contracts"
	var expected_capacity: int = int(Factory.CATALOG.power.capacity) + (int(Factory.CATALOG.power.upgrade_gain) if model.power_upgraded else 0)
	if model.power_capacity != expected_capacity or (not model.unlimited_power and model.power_used > model.power_capacity) or model.power_used > model.power_demand:
		return "Invalid power budget"
	return ""


func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "Save file missing or unreadable"}
	if file.get_length() > MAX_BYTES:
		file.close()
		return {"error": "Save exceeds size limit"}
	var text: String = file.get_as_text()
	file.close()
	return decode(text)


func load_game(path: String) -> Dictionary:
	var primary: Dictionary = _read(path)
	if not primary.has("error") or primary.get("unsupported", false):
		return primary
	var backup: Dictionary = _read(path + ".bak")
	if not backup.has("error"):
		backup.recovered = true
		return backup
	return {"error": "Primary: %s; backup: %s" % [primary.error, backup.error]}


func _replace_file(source: String, destination: String) -> Error:
	return DirAccess.rename_absolute(source, destination)


func save_game(model: Factory, path: String) -> Dictionary:
	var encoded: Dictionary = encode(model)
	if encoded.has("error"):
		return encoded
	var previous: Dictionary = _read(path)
	if previous.get("unsupported", false):
		return {"error": "Will not overwrite a save from an unsupported version"}
	var absolute: String = ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		return {"error": "Cannot create save directory"}
	var temporary: String = absolute + ".tmp-%d" % OS.get_process_id()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return {"error": "Cannot open temporary save"}
	file.store_string(encoded.document)
	file.flush()
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK or _read(temporary).has("error"):
		DirAccess.remove_absolute(temporary)
		return {"error": "Temporary save verification failed"}
	if not previous.has("error"):
		var backup_temporary: String = temporary + ".bak"
		if DirAccess.copy_absolute(absolute, backup_temporary) != OK or _read(backup_temporary).has("error") or _replace_file(backup_temporary, absolute + ".bak") != OK:
			DirAccess.remove_absolute(temporary)
			if FileAccess.file_exists(backup_temporary):
				DirAccess.remove_absolute(backup_temporary)
			return {"error": "Could not preserve previous save"}
	if _replace_file(temporary, absolute) != OK:
		DirAccess.remove_absolute(temporary)
		return {"error": "Could not replace primary save; previous progress retained"}
	return {"saved": true}