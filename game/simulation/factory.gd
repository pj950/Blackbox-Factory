extends RefCounted

const CATALOG = preload("res://content/catalog.tres")
const WIDTH: int = 24
const HEIGHT: int = 16
const TICK_SECONDS: float = 0.1
const DIRECTIONS: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]

var cash: int = 800
var cells: Dictionary = {}
var tick_count: int = 0
var supplied: int = 0
var collected: Dictionary = {"iron_plate": 0, "component": 0}
var test_sink_enabled: bool = false
var accumulator: float = 0.0
var pending_commands: Array = []
var command_errors: Array[String] = []
var contracts_enabled: bool = false
var order_index: int = 0
var order_active: bool = false
var order_progress: Dictionary = {"iron_plate": 0, "component": 0}
var fulfilled: Dictionary = {"iron_plate": 0, "component": 0}
var order_history: Array = []
var order_started_tick: int = 0
var unlimited_power: bool = true
var power_capacity: int = int(CATALOG.power.capacity)
var power_upgraded: bool = false
var power_used: int = 0
var power_demand: int = 0
var power_cursors: Array[int] = [0, 0, 0]
var delivery_samples: Array = []
var recent_delivery: Dictionary = {"iron_plate": 0, "component": 0}
var step_delivered: Dictionary = {"iron_plate": 0, "component": 0}
var wear_enabled: bool = false
var retired_machines: Dictionary = {"smelter": [], "press": []}


func _init(starting_cash: int = 800, contract_mode: bool = false) -> void:
	cash = starting_cash
	contracts_enabled = contract_mode
	unlimited_power = not contract_mode
	wear_enabled = contract_mode


func current_order() -> Dictionary:
	if not contracts_enabled or order_index >= CATALOG.orders.size():
		return {}
	return CATALOG.orders[order_index]


func accept_order() -> String:
	if not contracts_enabled:
		return "Orders are unavailable in test fixtures"
	if order_active:
		return "An order is already active"
	if current_order().is_empty():
		return "All contracts completed"
	order_active = true
	order_progress = {"iron_plate": 0, "component": 0}
	order_started_tick = tick_count
	return ""


func set_priority(cell: Vector2i, priority: int) -> String:
	if not cells.has(cell) or recipe_for(cells[cell]).is_empty():
		return "Select a processing machine"
	if priority < 0 or priority > 2:
		return "Invalid power priority"
	cells[cell].priority = priority
	return ""


func buy_power_upgrade() -> String:
	if unlimited_power:
		return "Unlimited test power does not need expansion"
	if power_upgraded:
		return "Power expansion already purchased"
	if cash < int(CATALOG.power.upgrade_cost):
		return "Insufficient funds for power expansion"
	cash -= int(CATALOG.power.upgrade_cost)
	power_capacity += int(CATALOG.power.upgrade_gain)
	power_upgraded = true
	return ""


func start_repair(cell: Vector2i) -> String:
	if not wear_enabled or not cells.has(cell) or recipe_for(cells[cell]).is_empty():
		return "Select a machine with maintenance enabled"
	var building: Dictionary = cells[cell]
	if building.repair_remaining > 0:
		return "Maintenance already in progress"
	if building.wear == 0:
		return "Machine is already in good condition"
	if cash < int(CATALOG.maintenance.repair_cost):
		return "Insufficient maintenance funds"
	cash -= int(CATALOG.maintenance.repair_cost)
	building.repair_remaining = int(CATALOG.maintenance.repair_ticks)
	return ""


func placement_error(kind: String, cell: Vector2i, facing: int = 0) -> String:
	if not CATALOG.buildings.has(kind):
		return "Unknown building"
	if cell.x < 0 or cell.y < 0 or cell.x >= WIDTH or cell.y >= HEIGHT:
		return "Outside factory boundary"
	if facing < 0 or facing >= DIRECTIONS.size():
		return "Invalid direction"
	if cells.has(cell):
		return "Cell occupied"
	if kind == "source" and cell != Vector2i(2, 7):
		return "Source requires the inlet at (2, 7)"
	if kind in ["source", "delivery"]:
		for building: Dictionary in cells.values():
			if building.kind == kind:
				return "Only one %s allowed" % kind
	if cash < int(CATALOG.buildings[kind].price):
		return "Insufficient funds"
	return ""


func place(kind: String, cell: Vector2i, facing: int = 0) -> String:
	var error: String = placement_error(kind, cell, facing)
	if not error.is_empty():
		return error
	cash -= int(CATALOG.buildings[kind].price)
	cells[cell] = {
		"kind": kind, "facing": facing, "input": [], "output": [],
		"active": false, "progress": 0, "enabled": true, "status": "idle",
		"next_transfer": 0, "next_supply": tick_count + 10, "split_cursor": 0,
		"merge_cursor": 0, "storage_item": "iron_ore", "produced": 0, "sent": 0,
		"priority": 1, "powered": false, "work_state": "idle",
		"samples": [], "recent_produced": 0, "recent_sent": 0, "status_counts": {},
		"step_produced": 0, "step_sent": 0,
		"wear": 0, "wear_phase": 0, "repair_remaining": 0,
	}
	if retired_machines.has(kind) and not retired_machines[kind].is_empty():
		var condition: Dictionary = retired_machines[kind].pop_front()
		cells[cell].wear = condition.wear
		cells[cell].wear_phase = condition.wear_phase
	return ""


func is_empty(building: Dictionary) -> bool:
	return building.input.is_empty() and building.output.is_empty() and not building.active


func remove(cell: Vector2i) -> String:
	if not cells.has(cell):
		return "No building"
	var building: Dictionary = cells[cell]
	if building.repair_remaining > 0:
		return "Finish maintenance before removing"
	if not is_empty(building):
		return "Drain materials before removing"
	cash += int(CATALOG.buildings[building.kind].price)
	if retired_machines.has(building.kind) and building.wear > 0:
		retired_machines[building.kind].append({"wear": building.wear, "wear_phase": building.wear_phase})
	cells.erase(cell)
	return ""


func rotate(cell: Vector2i) -> String:
	if not cells.has(cell):
		return "No building"
	var building: Dictionary = cells[cell]
	if building.repair_remaining > 0:
		return "Finish maintenance before rotating"
	if not is_empty(building):
		return "Drain materials before rotating"
	building.facing = (int(building.facing) + 1) % DIRECTIONS.size()
	return ""


func set_enabled(cell: Vector2i, enabled: bool) -> void:
	if cells.has(cell):
		cells[cell].enabled = enabled


func set_storage_item(cell: Vector2i, item: String) -> String:
	if not cells.has(cell) or cells[cell].kind != "storage":
		return "Select a warehouse"
	if item not in ["iron_ore", "iron_plate", "component"]:
		return "Unknown item"
	if not is_empty(cells[cell]):
		return "Drain warehouse before changing its item"
	cells[cell].storage_item = item
	return ""


func ordered_cells() -> Array:
	var positions: Array = cells.keys()
	positions.sort_custom(func(first: Vector2i, second: Vector2i) -> bool:
		return first.y * WIDTH + first.x < second.y * WIDTH + second.x)
	return positions


func advance(seconds: float) -> void:
	accumulator += maxf(seconds, 0.0)
	while accumulator + 0.000000001 >= TICK_SECONDS:
		accumulator = maxf(0.0, accumulator - TICK_SECONDS)
		step()


func execute_command(command: Dictionary) -> String:
	var cell: Vector2i = command.get("cell", Vector2i(-1, -1))
	match str(command.get("action", "")):
		"place":
			return place(command.kind, cell, int(command.get("facing", 0)))
		"remove":
			return remove(cell)
		"rotate":
			return rotate(cell)
		"enabled":
			if not cells.has(cell):
				return "No building"
			set_enabled(cell, bool(command.enabled))
			return ""
		"storage":
			return set_storage_item(cell, command.item)
		"accept_order":
			return accept_order()
		"priority":
			return set_priority(cell, int(command.priority))
		"power_upgrade":
			return buy_power_upgrade()
		"repair":
			return start_repair(cell)
	return "Unknown command"


func step() -> void:
	tick_count += 1
	var commands: Array = pending_commands
	pending_commands = []
	for command: Dictionary in commands:
		var error: String = execute_command(command)
		if not error.is_empty():
			command_errors.append(error)
	var positions: Array = ordered_cells()
	step_delivered = {"iron_plate": 0, "component": 0}
	for cell: Vector2i in positions:
		cells[cell].step_produced = 0
		cells[cell].step_sent = 0
		_prepare_machine(cells[cell])
	_allocate_power(positions)
	_transfer(positions)
	for cell: Vector2i in positions:
		var building: Dictionary = cells[cell]
		if building.kind == "source":
			_supply(building)
		elif building.kind == "delivery":
			_process_delivery(building)
		_update_status(building, cell)
		_record_diagnostics(building)
	delivery_samples.append(step_delivered.duplicate())
	for item: String in recent_delivery:
		recent_delivery[item] += int(step_delivered[item])
	if delivery_samples.size() > 300:
		var expired: Dictionary = delivery_samples.pop_front()
		for item: String in recent_delivery:
			recent_delivery[item] -= int(expired[item])


func _process_delivery(building: Dictionary) -> void:
	if not contracts_enabled:
		if test_sink_enabled:
			for packet: Dictionary in building.output:
				collected[packet.item] += 1
			building.output.clear()
		return
	if not order_active:
		return
	var order: Dictionary = current_order()
	var remaining: Array = []
	for packet: Dictionary in building.output:
		if int(order_progress[packet.item]) < int(order.requirements[packet.item]):
			order_progress[packet.item] += 1
			fulfilled[packet.item] += 1
			step_delivered[packet.item] += 1
		else:
			remaining.append(packet)
	building.output = remaining
	for item: String in order.requirements:
		if int(order_progress[item]) < int(order.requirements[item]):
			return
	cash += int(order.reward)
	order_history.append({"id": order.id, "reward": order.reward, "elapsed_ticks": tick_count - order_started_tick, "completed_tick": tick_count})
	order_active = false
	order_index += 1


func recipe_for(building: Dictionary) -> Dictionary:
	var definition: Dictionary = CATALOG.buildings[building.kind]
	if not definition.has("recipe"):
		return {}
	return CATALOG.recipes[definition.recipe]


func _prepare_machine(building: Dictionary) -> void:
	var recipe: Dictionary = recipe_for(building)
	building.powered = false
	building.work_state = "disabled" if not building.enabled else "idle"
	if building.repair_remaining > 0:
		building.repair_remaining -= 1
		building.work_state = "maintenance"
		if building.repair_remaining == 0:
			building.wear = 0
			building.wear_phase = 0
		return
	if recipe.is_empty() or not building.enabled:
		return
	if not building.active:
		if building.output.size() + int(recipe.output_count) > int(CATALOG.buildings[building.kind].capacity):
			building.work_state = "output blocked"
			return
		if building.input.size() < int(recipe.input_count):
			building.work_state = "missing input"
			return
		for amount: int in range(int(recipe.input_count)):
			building.input.pop_front()
		building.active = true
		building.progress = 0
	building.work_state = "no power"


func _allocate_power(positions: Array) -> void:
	power_used = 0
	power_demand = 0
	var groups: Array = [[], [], []]
	for cell: Vector2i in positions:
		var building: Dictionary = cells[cell]
		if building.active and building.enabled and building.work_state == "no power":
			groups[int(building.priority)].append(cell)
			power_demand += int(recipe_for(building).power)
	for priority: int in range(3):
		var cursor: int = power_cursors[priority]
		groups[priority].sort_custom(func(first: Vector2i, second: Vector2i) -> bool:
			return (first.y * WIDTH + first.x - cursor + WIDTH * HEIGHT) % (WIDTH * HEIGHT) < (second.y * WIDTH + second.x - cursor + WIDTH * HEIGHT) % (WIDTH * HEIGHT))
		for cell: Vector2i in groups[priority]:
			var building: Dictionary = cells[cell]
			var required: int = int(recipe_for(building).power)
			if not unlimited_power and power_used + required > power_capacity:
				continue
			power_used += required
			building.powered = true
			building.work_state = "processing"
			power_cursors[priority] = (cell.y * WIDTH + cell.x + 1) % (WIDTH * HEIGHT)
			_progress_machine(building)


func _progress_machine(building: Dictionary) -> void:
	var recipe: Dictionary = recipe_for(building)
	if wear_enabled:
		var degraded: bool = building.wear >= int(CATALOG.maintenance.wear_limit)
		building.wear = mini(int(CATALOG.maintenance.wear_limit), int(building.wear) + 1)
		if degraded:
			building.work_state = "degraded"
			building.wear_phase = (int(building.wear_phase) + 1) % 2
			if building.wear_phase != 0:
				return
	building.progress += 1
	if building.progress >= int(recipe.ticks):
		for amount: int in range(int(recipe.output_count)):
			building.output.append({"item": recipe.output, "ready": tick_count})
		building.active = false
		building.progress = 0
		building.produced += int(recipe.output_count)
		building.step_produced += int(recipe.output_count)


func _supply(building: Dictionary) -> void:
	if tick_count < int(building.next_supply):
		return
	if not building.enabled or building.output.size() >= int(CATALOG.buildings.source.capacity):
		return
	building.output.append({"item": "iron_ore", "ready": tick_count + 1})
	building.next_supply = tick_count + int(CATALOG.buildings.source.interval)
	supplied += 1


func _accepts(building: Dictionary, item: String, incoming_side: int) -> bool:
	var kind: String = building.kind
	if kind == "source":
		return false
	if kind == "delivery":
		return item in ["iron_plate", "component"]
	if kind == "belt":
		return incoming_side != int(building.facing)
	if incoming_side != (int(building.facing) + 2) % 4:
		return false
	if kind == "splitter":
		return true
	if kind == "storage":
		return item == building.storage_item
	return item == recipe_for(building).input


func input_items(building: Dictionary, incoming_side: int) -> Array[String]:
	var items: Array[String] = []
	for item: String in ["iron_ore", "iron_plate", "component"]:
		if _accepts(building, item, incoming_side):
			items.append(item)
	return items


func output_sides(building: Dictionary) -> Array[int]:
	if building.kind == "delivery":
		return []
	if building.kind == "splitter":
		return [int(building.facing), (int(building.facing) + 1) % 4]
	return [int(building.facing)]


func _receiver_queue(building: Dictionary) -> Array:
	return building.input if not recipe_for(building).is_empty() else building.output


func _free_slots(building: Dictionary, item: String, reserved: Dictionary) -> int:
	var occupied: int = 0
	var queue: Array = _receiver_queue(building)
	if building.kind == "delivery":
		for packet: Dictionary in queue:
			if packet.item == item:
				occupied += 1
		occupied += int(reserved.get(item, 0))
	else:
		occupied = queue.size()
		for count: int in reserved.values():
			occupied += count
	return int(CATALOG.buildings[building.kind].capacity) - occupied


func _candidates(cell: Vector2i, building: Dictionary) -> Array:
	var candidates: Array = []
	if building.kind == "delivery" or building.output.is_empty():
		return candidates
	if not building.enabled and building.kind in ["belt", "splitter", "storage"]:
		return candidates
	if tick_count < int(building.next_transfer) or tick_count < int(building.output[0].ready):
		return candidates
	var item: String = building.output[0].item
	var exits: Array[int] = output_sides(building)
	if building.kind == "splitter" and int(building.split_cursor) == 1:
		exits.reverse()
	for direction: int in exits:
		var target: Vector2i = cell + DIRECTIONS[direction]
		var incoming: int = (direction + 2) % 4
		if not cells.has(target) or not _accepts(cells[target], item, incoming):
			continue
		if _free_slots(cells[target], item, {}) <= 0:
			continue
		candidates.append({"from": cell, "to": target, "item": item, "incoming": incoming, "exit": direction})
	return candidates


func _transfer(positions: Array) -> void:
	var candidates: Dictionary = {}
	for cell: Vector2i in positions:
		candidates[cell] = _candidates(cell, cells[cell])
	var claimed: Dictionary = {}
	var reserved: Dictionary = {}
	var plans: Array = []
	for attempt: int in range(2):
		var requests: Dictionary = {}
		for cell: Vector2i in positions:
			if claimed.has(cell) or candidates[cell].size() <= attempt:
				continue
			var candidate: Dictionary = candidates[cell][attempt]
			if not requests.has(candidate.to):
				requests[candidate.to] = []
			requests[candidate.to].append(candidate)
		for target: Vector2i in positions:
			if not requests.has(target):
				continue
			var cursor: int = cells[target].merge_cursor
			requests[target].sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
				return (int(first.incoming) - cursor + 4) % 4 < (int(second.incoming) - cursor + 4) % 4)
			if not reserved.has(target):
				reserved[target] = {}
			for request: Dictionary in requests[target]:
				if _free_slots(cells[target], request.item, reserved[target]) <= 0:
					continue
				plans.append(request)
				claimed[request.from] = true
				reserved[target][request.item] = int(reserved[target].get(request.item, 0)) + 1
				cells[target].merge_cursor = (int(request.incoming) + 1) % 4
	for plan: Dictionary in plans:
		var sender: Dictionary = cells[plan.from]
		sender.output.pop_front()
		sender.sent += 1
		sender.step_sent += 1
		var interval: int = 1
		if sender.kind in ["belt", "splitter", "storage"]:
			interval = int(CATALOG.buildings[sender.kind].interval)
		sender.next_transfer = tick_count + interval
		if sender.kind == "splitter":
			sender.split_cursor = 1 if int(plan.exit) == int(sender.facing) else 0
	for plan: Dictionary in plans:
		var receiver: Dictionary = cells[plan.to]
		var delay: int = 5 if receiver.kind in ["belt", "splitter", "storage"] else 1
		_receiver_queue(receiver).append({"item": plan.item, "ready": tick_count + delay})


func _update_status(building: Dictionary, cell: Vector2i) -> void:
	if not building.enabled:
		building.status = "disabled"
		return
	var recipe: Dictionary = recipe_for(building)
	if not recipe.is_empty():
		building.status = building.work_state
	elif building.kind == "delivery":
		building.status = "receiving"
	elif building.output.is_empty():
		building.status = "idle"
	elif tick_count < int(building.next_transfer) or tick_count < int(building.output[0].ready):
		building.status = "transporting"
	else:
		building.status = "output blocked" if _candidates(cell, building).is_empty() else "transporting"


func _record_diagnostics(building: Dictionary) -> void:
	var sample: Dictionary = {"produced": building.step_produced, "sent": building.step_sent, "status": building.status}
	building.samples.append(sample)
	building.recent_produced += int(sample.produced)
	building.recent_sent += int(sample.sent)
	building.status_counts[sample.status] = int(building.status_counts.get(sample.status, 0)) + 1
	if building.samples.size() > 300:
		var expired: Dictionary = building.samples.pop_front()
		building.recent_produced -= int(expired.produced)
		building.recent_sent -= int(expired.sent)
		building.status_counts[expired.status] -= 1
		if building.status_counts[expired.status] == 0:
			building.status_counts.erase(expired.status)


func diagnostics(cell: Vector2i) -> Dictionary:
	if not cells.has(cell):
		return {}
	var building: Dictionary = cells[cell]
	var sample_count: int = building.samples.size()
	var rates: Dictionary = {"seconds": sample_count * TICK_SECONDS, "produced_per_minute": 0.0, "sent_per_minute": 0.0, "states": {}}
	if sample_count == 0:
		return rates
	rates.produced_per_minute = float(building.recent_produced) * 600.0 / sample_count
	rates.sent_per_minute = float(building.recent_sent) * 600.0 / sample_count
	for state: String in building.status_counts:
		rates.states[state] = float(building.status_counts[state]) / sample_count
	return rates


func delivery_per_minute(item: String) -> float:
	return float(recent_delivery.get(item, 0)) * 600.0 / delivery_samples.size() if not delivery_samples.is_empty() else 0.0


func item_count(cell: Vector2i, item: String) -> int:
	if not cells.has(cell):
		return 0
	var count: int = 0
	for packet: Dictionary in cells[cell].input + cells[cell].output:
		if packet.item == item:
			count += 1
	return count


func ore_equivalent() -> int:
	var total: int = int(collected.iron_plate) + 2 * int(collected.component)
	total += int(fulfilled.iron_plate) + 2 * int(fulfilled.component)
	for building: Dictionary in cells.values():
		for packet: Dictionary in building.input + building.output:
			total += 2 if packet.item == "component" else 1
		if building.active:
			var recipe: Dictionary = recipe_for(building)
			var weight: int = 2 if recipe.input == "component" else 1
			total += int(recipe.input_count) * weight
	return total


func snapshot() -> Dictionary:
	var buildings: Array = []
	for cell: Vector2i in ordered_cells():
		buildings.append({"cell": cell, "state": cells[cell].duplicate(true)})
	return {
		"tick": tick_count, "cash": cash, "supplied": supplied,
		"collected": collected.duplicate(), "sink": test_sink_enabled, "buildings": buildings,
		"pending": pending_commands.duplicate(true), "errors": command_errors.duplicate(),
		"contracts": contracts_enabled, "order_index": order_index, "order_active": order_active,
		"order_progress": order_progress.duplicate(), "fulfilled": fulfilled.duplicate(),
		"order_history": order_history.duplicate(true), "order_started": order_started_tick,
		"unlimited_power": unlimited_power, "capacity": power_capacity, "upgraded": power_upgraded,
		"power_used": power_used, "power_demand": power_demand, "power_cursors": power_cursors.duplicate(),
		"delivery_samples": delivery_samples.duplicate(true), "recent_delivery": recent_delivery.duplicate(),
		"wear_enabled": wear_enabled, "retired_machines": retired_machines.duplicate(true),
	}