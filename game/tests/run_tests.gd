extends SceneTree

const Factory = preload("res://simulation/factory.gd")
const Fixtures = preload("res://simulation/fixtures.gd")
const SaveStore = preload("res://persistence/save_store.gd")

class RefusingSaveStore extends "res://persistence/save_store.gd":
	func _replace_file(_source: String, _destination: String) -> Error:
		return ERR_FILE_CANT_WRITE

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	test_grid()
	test_command_boundary()
	test_orders()
	test_power()
	test_diagnostics()
	test_flow_and_backpressure()
	test_material_guards()
	test_ports_and_one_hop()
	test_splitter()
	test_merge()
	test_determinism()
	test_throughput()
	test_limited_throughput()
	test_contract_route()
	test_contract_route(true)
	test_maintenance()
	test_saves()
	print("Factory tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(label)


func test_grid() -> void:
	var model = Factory.new()
	expect(not model.place("belt", Vector2i(-1, 0)).is_empty(), "Reject outside map")
	expect(not model.place("belt", Vector2i(24, 0)).is_empty(), "Reject right boundary")
	expect(not model.place("belt", Vector2i(0, 16)).is_empty(), "Reject lower boundary")
	expect(not model.place("missing", Vector2i.ZERO).is_empty(), "Reject unknown kind")
	expect(not model.place("belt", Vector2i.ZERO, 4).is_empty(), "Reject invalid facing")
	expect(model.cash == 800 and model.cells.is_empty(), "Rejected commands are atomic")
	expect(model.place("belt", Vector2i.ZERO).is_empty(), "Place belt")
	expect(not model.place("belt", Vector2i.ZERO).is_empty(), "Reject overlap")
	expect(model.cash == 795 and model.cells.size() == 1, "Overlap does not charge")
	expect(model.rotate(Vector2i.ZERO).is_empty(), "Rotate empty belt")
	expect(model.cells[Vector2i.ZERO].facing == 1, "Rotation is clockwise")
	expect(model.remove(Vector2i.ZERO).is_empty() and model.cash == 800, "Refund empty building")
	expect(not model.remove(Vector2i.ZERO).is_empty() and model.cash == 800, "No duplicate refund")
	expect(not model.place("source", Vector2i.ZERO).is_empty(), "Source inlet is fixed")
	expect(model.place("source", Vector2i(2, 7)).is_empty(), "Place source")
	expect(model.place("delivery", Vector2i(18, 7)).is_empty(), "Place delivery")
	expect(not model.place("delivery", Vector2i(19, 7)).is_empty(), "Delivery is unique")
	var poor = Factory.new(4)
	expect(not poor.place("belt", Vector2i.ZERO).is_empty(), "Reject unaffordable build")
	expect(poor.cash == 4 and poor.cells.is_empty(), "Insufficient funds is atomic")


func run_steps(model: Factory, count: int) -> void:
	for tick: int in range(count):
		model.step()
		expect(model.ore_equivalent() == model.supplied, "Ore-equivalent conservation at tick %d" % model.tick_count)
		if not model.unlimited_power:
			expect(model.power_used <= model.power_capacity, "Power budget at tick %d" % model.tick_count)


func test_command_boundary() -> void:
	var model = Factory.new()
	model.pending_commands.append({"action": "place", "kind": "belt", "cell": Vector2i.ZERO})
	model.pending_commands.append({"action": "rotate", "cell": Vector2i.ZERO})
	model.advance(0.05)
	expect(model.cells.is_empty() and model.cash == 800, "Commands wait for tick boundary")
	model.advance(0.05)
	expect(model.cells[Vector2i.ZERO].facing == 1 and model.cash == 795, "Commands apply in submission order")
	model.pending_commands.append({"action": "place", "kind": "belt", "cell": Vector2i.ZERO})
	model.step()
	expect(model.command_errors.size() == 1 and model.cash == 795, "Queued rejection is atomic and reported")
	expect(model.pending_commands.is_empty(), "Commands execute exactly once")


func seed_materials(model: Factory, cell: Vector2i, item: String, count: int, machine_input: bool = false) -> void:
	var queue: Array = model.cells[cell].input if machine_input else model.cells[cell].output
	for amount: int in range(count):
		queue.append({"item": item, "ready": model.tick_count})
		model.supplied += 2 if item == "component" else 1


func test_flow_and_backpressure() -> void:
	var model = Fixtures.create("plate")
	expect(model.cells.size() == 17 and model.cash == 470, "Plate fixture geometry and cost")
	run_steps(model, 1000)
	expect(model.item_count(Vector2i(18, 7), "iron_plate") >= 40, "O1 layout delivers iron plate")
	run_steps(model, 3000)
	expect(model.item_count(Vector2i(18, 7), "iron_plate") == 64, "Delivery has finite capacity")
	expect(model.cells[Vector2i(6, 7)].status == "output blocked", "Backpressure reaches furnace")
	var previous_supply: int = model.supplied
	run_steps(model, 200)
	expect(model.supplied == previous_supply, "Blocked source stops supplying")
	model.test_sink_enabled = true
	run_steps(model, 500)
	expect(model.supplied > previous_supply and model.collected.iron_plate > 64, "Unblocking resumes production")


func test_orders() -> void:
	var model = Factory.new(800, true)
	var station := Vector2i(18, 7)
	model.place("delivery", station)
	seed_materials(model, station, "iron_plate", 20)
	seed_materials(model, station, "component", 15)
	model.test_sink_enabled = true
	run_steps(model, 1)
	expect(model.item_count(station, "iron_plate") == 20 and model.collected.iron_plate == 0, "Contract stock cannot be consumed by fixture collector")
	expect(model.accept_order().is_empty(), "Accept O1")
	expect(not model.accept_order().is_empty(), "Reject duplicate acceptance")
	run_steps(model, 1)
	expect(model.order_index == 1 and not model.order_active and model.cash == 940, "O1 pays exactly 200 after consuming 12 plates")
	expect(model.item_count(station, "iron_plate") == 8 and model.item_count(station, "component") == 15, "Surplus and unrelated products stay cached")
	run_steps(model, 10)
	expect(model.cash == 940 and model.order_history.size() == 1, "Completed order cannot pay again")
	expect(model.accept_order().is_empty(), "Accept O2 explicitly")
	run_steps(model, 1)
	expect(model.order_active and model.order_progress.iron_plate == 8 and model.order_progress.component == 12, "O2 uses spare stock but not already delivered O1 goods")
	expect(model.cash == 940, "Partial order pays nothing")
	seed_materials(model, station, "iron_plate", 6)
	run_steps(model, 1)
	expect(model.cash == 1200 and model.order_index == 2, "O2 pays 260 exactly once")
	expect(model.item_count(station, "iron_plate") == 2 and model.item_count(station, "component") == 3, "O2 excess remains available")
	expect(model.accept_order().is_empty(), "Accept O3")
	seed_materials(model, station, "component", 27)
	run_steps(model, 1)
	expect(model.cash == 1600 and model.order_history.size() == 3, "O3 pays 400 and completes the sequence")
	expect(model.current_order().is_empty() and not model.accept_order().is_empty(), "No repeatable final contract")
	expect(model.fulfilled.iron_plate == 24 and model.fulfilled.component == 42, "Lifetime delivered totals are separate from buffers")
	run_steps(model, 10)
	expect(model.cash == 1600 and model.ore_equivalent() == model.supplied, "Final reward cannot repeat and delivered goods remain conserved")
	var fixture = Factory.new()
	expect(not fixture.accept_order().is_empty(), "Fixture cannot start contracts")


func test_material_guards() -> void:
	var model = Factory.new()
	model.place("smelter", Vector2i(6, 7))
	seed_materials(model, Vector2i(6, 7), "iron_ore", 1, true)
	expect(not model.remove(Vector2i(6, 7)).is_empty(), "Cannot remove buffered materials")
	model.step()
	expect(model.cells[Vector2i(6, 7)].active, "Machine starts batch")
	expect(not model.rotate(Vector2i(6, 7)).is_empty(), "Cannot rotate in-progress batch")
	expect(not model.remove(Vector2i(6, 7)).is_empty(), "Cannot remove in-progress batch")
	model.set_enabled(Vector2i(6, 7), false)
	var progress: int = model.cells[Vector2i(6, 7)].progress
	run_steps(model, 50)
	expect(model.cells[Vector2i(6, 7)].progress == progress, "Disabled machine preserves progress")
	model.set_enabled(Vector2i(6, 7), true)
	run_steps(model, 19)
	expect(model.item_count(Vector2i(6, 7), "iron_plate") == 1, "Resumed batch finishes once")
	expect(not model.remove(Vector2i(6, 7)).is_empty(), "Cannot remove output stock")
	model.place("storage", Vector2i(7, 7))
	expect(model.set_storage_item(Vector2i(7, 7), "iron_plate").is_empty(), "Configure empty warehouse")
	run_steps(model, 1)
	expect(model.remove(Vector2i(6, 7)).is_empty(), "Drained machine can be removed")
	expect(not model.set_storage_item(Vector2i(7, 7), "component").is_empty(), "Cannot change occupied warehouse type")


func test_power() -> void:
	var model = Factory.new(800, true)
	var furnace := Vector2i(0, 0)
	model.place("smelter", furnace)
	seed_materials(model, furnace, "iron_ore", 1, true)
	model.power_capacity = 0
	run_steps(model, 5)
	expect(model.cells[furnace].active and model.cells[furnace].progress == 0, "No power preserves a reserved batch without progress")
	expect(model.cells[furnace].input.is_empty() and model.cells[furnace].status == "no power", "Missing power is not missing ingredients")
	model.power_capacity = 4
	run_steps(model, 20)
	expect(model.cells[furnace].produced == 1 and not model.cells[furnace].active, "Restored power finishes once")
	run_steps(model, 1)
	expect(model.power_used == 0 and model.power_demand == 0, "Idle machine draws no power")
	var fair = Factory.new(800, true)
	fair.power_capacity = 4
	for cell: Vector2i in [Vector2i(0, 0), Vector2i(2, 0)]:
		fair.place("smelter", cell)
		seed_materials(fair, cell, "iron_ore", 4, true)
	run_steps(fair, 20)
	expect(fair.cells[Vector2i(0, 0)].progress == 10 and fair.cells[Vector2i(2, 0)].progress == 10, "Equal priority receives round-robin power")
	expect(fair.set_priority(Vector2i.ZERO, 0).is_empty(), "Set high priority")
	var low_progress: int = fair.cells[Vector2i(2, 0)].progress
	run_steps(fair, 10)
	expect(fair.cells[Vector2i.ZERO].produced == 1 and fair.cells[Vector2i(2, 0)].progress == low_progress, "High priority wins constrained power")
	expect(not fair.set_priority(Vector2i.ZERO, 3).is_empty(), "Reject invalid priority")
	var skip = Factory.new(800, true)
	skip.power_capacity = 4
	skip.place("press", Vector2i.ZERO)
	skip.place("smelter", Vector2i(2, 0))
	seed_materials(skip, Vector2i.ZERO, "iron_plate", 2, true)
	seed_materials(skip, Vector2i(2, 0), "iron_ore", 1, true)
	skip.set_priority(Vector2i.ZERO, 0)
	run_steps(skip, 1)
	expect(not skip.cells[Vector2i.ZERO].powered and skip.cells[Vector2i(2, 0)].powered, "Skip unaffordable machine and power smaller candidate")
	var upgrade = Factory.new(800, true)
	expect(upgrade.buy_power_upgrade().is_empty() and upgrade.cash == 560 and upgrade.power_capacity == 14, "Upgrade costs 240 and adds four power")
	expect(not upgrade.buy_power_upgrade().is_empty() and upgrade.cash == 560, "Upgrade cannot be bought twice")
	var poor = Factory.new(239, true)
	expect(not poor.buy_power_upgrade().is_empty() and poor.cash == 239 and poor.power_capacity == 10, "Unaffordable upgrade is atomic")
	var fixture = Factory.new()
	expect(not fixture.buy_power_upgrade().is_empty(), "Unlimited fixture cannot buy power")
	var first = Fixtures.create("double")
	var second = Fixtures.create("double")
	first.unlimited_power = false
	second.unlimited_power = false
	var reversed_cells: Dictionary = {}
	var positions: Array = second.ordered_cells()
	positions.reverse()
	for cell: Vector2i in positions:
		reversed_cells[cell] = second.cells[cell]
	second.cells = reversed_cells
	first.advance(60.0)
	for frame: int in range(1800):
		second.advance(1.0 / 30.0)
	expect(first.snapshot() == second.snapshot(), "Finite-power arbitration is insertion-order and frame-rate independent")


func test_diagnostics() -> void:
	var model = Factory.new(800, true)
	model.place("smelter", Vector2i.ZERO)
	run_steps(model, 10)
	var report: Dictionary = model.diagnostics(Vector2i.ZERO)
	expect(is_equal_approx(report.seconds, 1.0) and is_equal_approx(report.states["missing input"], 1.0), "Short diagnostic window uses actual running time")
	model.set_enabled(Vector2i.ZERO, false)
	run_steps(model, 300)
	report = model.diagnostics(Vector2i.ZERO)
	expect(is_equal_approx(report.seconds, 30.0) and not report.states.has("missing input"), "Rolling window expires old states")
	expect(is_equal_approx(report.states.disabled, 1.0) and model.cells[Vector2i.ZERO].samples.size() == 300, "Diagnostic history is bounded")
	var before: Dictionary = report.duplicate(true)
	model.advance(0.0)
	expect(model.diagnostics(Vector2i.ZERO) == before, "No simulated time means no new diagnostic sample")
	var flow = Fixtures.create("component")
	flow.test_sink_enabled = true
	run_steps(flow, 1200)
	report = flow.diagnostics(Vector2i(12, 7))
	expect(report.produced_per_minute >= 14.0 and report.produced_per_minute <= 16.0, "Production window reports completed items")
	expect(flow.delivery_per_minute("component") == 0.0, "Test collection is not order delivery")
	var order = Factory.new(800, true)
	order.place("delivery", Vector2i.ZERO)
	order.accept_order()
	seed_materials(order, Vector2i.ZERO, "iron_plate", 12)
	run_steps(order, 300)
	expect(is_equal_approx(order.delivery_per_minute("iron_plate"), 24.0), "Order delivery rate has its own counter")
	run_steps(order, 1)
	expect(order.delivery_per_minute("iron_plate") == 0.0, "Old order deliveries expire from rate window")


func test_ports_and_one_hop() -> void:
	var model = Factory.new()
	for column: int in range(3):
		model.place("belt", Vector2i(column, 0))
	seed_materials(model, Vector2i.ZERO, "iron_ore", 1)
	run_steps(model, 1)
	expect(model.item_count(Vector2i(1, 0), "iron_ore") == 1, "First transfer occurs")
	expect(model.item_count(Vector2i(2, 0), "iron_ore") == 0, "Cannot move twice in one tick")
	run_steps(model, 4)
	expect(model.item_count(Vector2i(1, 0), "iron_ore") == 1, "Belt minimum residence is five ticks")
	run_steps(model, 1)
	expect(model.item_count(Vector2i(2, 0), "iron_ore") == 1, "Belt advances after residence")
	var reversed = Factory.new()
	reversed.place("belt", Vector2i.ZERO)
	reversed.place("belt", Vector2i(1, 0), 2)
	seed_materials(reversed, Vector2i.ZERO, "iron_ore", 1)
	run_steps(reversed, 10)
	expect(reversed.item_count(Vector2i.ZERO, "iron_ore") == 1, "Reject head-on belt input")
	var wrong_item = Factory.new()
	wrong_item.place("belt", Vector2i.ZERO)
	wrong_item.place("press", Vector2i(1, 0))
	seed_materials(wrong_item, Vector2i.ZERO, "iron_ore", 1)
	run_steps(wrong_item, 10)
	expect(wrong_item.item_count(Vector2i.ZERO, "iron_ore") == 1, "Machine rejects wrong ingredient")
	var delivery = Factory.new()
	delivery.place("belt", Vector2i.ZERO)
	delivery.place("delivery", Vector2i(1, 0))
	seed_materials(delivery, Vector2i.ZERO, "iron_ore", 1)
	run_steps(delivery, 10)
	expect(delivery.item_count(Vector2i.ZERO, "iron_ore") == 1, "Delivery rejects ore")


func test_splitter() -> void:
	var model = Factory.new()
	model.place("splitter", Vector2i.ZERO)
	model.place("storage", Vector2i(1, 0))
	model.place("storage", Vector2i(0, 1), 1)
	for tick: int in range(200):
		if model.cells[Vector2i.ZERO].output.is_empty():
			seed_materials(model, Vector2i.ZERO, "iron_ore", 1)
		run_steps(model, 1)
	var front: int = model.item_count(Vector2i(1, 0), "iron_ore")
	var side: int = model.item_count(Vector2i(0, 1), "iron_ore")
	expect(front >= 19 and absi(front - side) <= 1, "Splitter alternates clear exits")
	seed_materials(model, Vector2i(1, 0), "iron_ore", 32 - front)
	for tick: int in range(60):
		if model.cells[Vector2i.ZERO].output.is_empty():
			seed_materials(model, Vector2i.ZERO, "iron_ore", 1)
		run_steps(model, 1)
	expect(model.item_count(Vector2i(0, 1), "iron_ore") > side, "Blocked branch does not stop other exit")
	expect(model.item_count(Vector2i(1, 0), "iron_ore") == 32, "No overflow at blocked branch")


func test_merge() -> void:
	var model = Factory.new()
	model.place("storage", Vector2i(4, 5))
	model.place("storage", Vector2i(5, 4), 1)
	model.place("belt", Vector2i(5, 5))
	model.place("storage", Vector2i(6, 5))
	seed_materials(model, Vector2i(4, 5), "iron_ore", 32)
	seed_materials(model, Vector2i(5, 4), "iron_ore", 32)
	run_steps(model, 200)
	var first_sent: int = model.cells[Vector2i(4, 5)].sent
	var second_sent: int = model.cells[Vector2i(5, 4)].sent
	expect(first_sent >= 16 and second_sent >= 16, "Both merging senders make progress")
	expect(absi(first_sent - second_sent) <= 1, "Merge contention is fair")
	expect(model.cells[Vector2i(5, 5)].output.size() <= 2, "Merge never overflows belt")


func test_determinism() -> void:
	var first = Fixtures.create("component")
	var second = Fixtures.create("component")
	var reversed_cells: Dictionary = {}
	var positions: Array = second.ordered_cells()
	positions.reverse()
	for cell: Vector2i in positions:
		reversed_cells[cell] = second.cells[cell]
	second.cells = reversed_cells
	for frame: int in range(1800):
		first.advance(1.0 / 30.0)
	for frame: int in range(8640):
		second.advance(1.0 / 144.0)
	expect(first.tick_count == 600 and second.tick_count == 600, "Frame rates execute equal ticks")
	expect(first.snapshot() == second.snapshot(), "Simulation ignores render rate and insertion order")
	var delayed = Fixtures.create("component")
	delayed.advance(60.0)
	expect(first.snapshot() == delayed.snapshot(), "Large frame delta does not silently drop ticks")


func test_throughput() -> void:
	for mode: String in ["component", "double"]:
		var model = Fixtures.create(mode)
		model.test_sink_enabled = true
		expect(model.cells.size() == (28 if mode == "double" else 17), "Fixture building count: " + mode)
		expect(model.cash == (280 if mode == "double" else 295), "Fixture budget: " + mode)
		run_steps(model, 1200)
		var before: int = model.collected.component
		run_steps(model, 3600)
		var count: int = model.collected.component - before
		var expected: int = 120 if mode == "double" else 90
		expect(absi(count - expected) <= 1, "Steady-state throughput: " + mode)
		print("Throughput %s: %d components in 360 seconds (%.2f/min)" % [mode, count, count / 6.0])


func test_limited_throughput() -> void:
	for upgraded: bool in [false, true]:
		var model = Fixtures.create("double")
		model.unlimited_power = false
		model.test_sink_enabled = true
		if upgraded:
			expect(model.buy_power_upgrade().is_empty(), "Expanded fixture can afford power upgrade")
		run_steps(model, 1200)
		var before: int = model.collected.component
		run_steps(model, 3600)
		var amount: int = model.collected.component - before
		if upgraded:
			expect(absi(amount - 120) <= 1, "Finite 14 power reaches press capacity")
		else:
			expect(amount > 0 and amount < 120, "Finite 10 power cannot sustain full press capacity")
		print("Finite power %d: %d components in 360 seconds (%.2f/min)" % [model.power_capacity, amount, amount / 6.0])


func until(model: Factory, condition: Callable, limit: int, label: String) -> void:
	for tick: int in range(limit):
		if condition.call():
			break
		run_steps(model, 1)
	expect(condition.call(), label)


func test_contract_route(with_wear: bool = false) -> void:
	var model = Fixtures.create("contract")
	model.wear_enabled = with_wear
	expect(model.cash == 800 and model.cells.is_empty() and not model.unlimited_power, "Contract starts empty with finite power and 800 credits")
	expect(model.accept_order().is_empty(), "Route accepts O1")
	for entry: Array in [["source", 2], ["smelter", 6], ["delivery", 18]]:
		expect(model.place(entry[0], Vector2i(entry[1], 7)).is_empty(), "Route places " + entry[0])
	for column: int in range(3, 18):
		if column != 6:
			expect(model.place("belt", Vector2i(column, 7)).is_empty(), "Route places baseline belt")
	expect(model.cash == 470, "Actual O1 construction costs 330")
	until(model, func() -> bool: return model.order_index == 1, 2000, "Route completes O1")
	expect(model.cash == 670, "Actual O1 reward leaves 670")
	model.accept_order()
	until(model, func() -> bool: return model.order_progress.iron_plate == 12, 2000, "Route delivers O2 plates before switching")
	model.set_enabled(Vector2i(2, 7), false)
	until(model, func() -> bool:
		for cell: Vector2i in model.cells:
			if model.cells[cell].kind != "delivery" and not model.is_empty(model.cells[cell]):
				return false
		return true, 2000, "Source shutdown drains the iron plate line")
	expect(model.remove(Vector2i(12, 7)).is_empty(), "Drain permits conversion without deleting materials")
	expect(model.place("press", Vector2i(12, 7)).is_empty(), "Route buys press")
	model.set_enabled(Vector2i(2, 7), true)
	until(model, func() -> bool: return model.order_index == 2, 3000, "Route completes O2")
	expect(model.cash == 755, "Actual O2 conversion and reward leave 755")
	model.set_enabled(Vector2i(2, 7), false)
	until(model, func() -> bool: return model.is_empty(model.cells[Vector2i(2, 7)]) and model.is_empty(model.cells[Vector2i(3, 7)]), 2000, "Drain source branch for second furnace")
	expect(model.remove(Vector2i(3, 7)).is_empty(), "Remove drained branch belt")
	expect(model.place("splitter", Vector2i(3, 7)).is_empty(), "Buy splitter")
	expect(model.place("smelter", Vector2i(6, 10)).is_empty(), "Buy second furnace")
	for entry: Array in [[3, 8, 1], [3, 9, 1], [3, 10, 0], [4, 10, 0], [5, 10, 0], [7, 10, 0], [8, 10, 0], [9, 10, 3], [9, 9, 3], [9, 8, 3]]:
		expect(model.place("belt", Vector2i(entry[0], entry[1]), entry[2]).is_empty(), "Buy expansion belt")
	expect(model.cash == 540, "Actual logistics expansion costs 215")
	expect(model.buy_power_upgrade().is_empty() and model.cash == 300, "Order income funds power expansion")
	model.accept_order()
	model.set_enabled(Vector2i(2, 7), true)
	until(model, func() -> bool: return model.order_index == 3, 3000, "Route completes O3")
	expect(model.cash == 700 and model.order_history.size() == 3, "Full route finishes with planned 700 credits")
	expect(model.collected.component == 0 and model.collected.iron_plate == 0, "Full route does not use test collector")
	print("Contract route (wear=%s): %d ticks, final credits %d, delivered %d plates / %d components" % [with_wear, model.tick_count, model.cash, model.fulfilled.iron_plate, model.fulfilled.component])


func test_maintenance() -> void:
	var model = Factory.new(800, true)
	var furnace := Vector2i.ZERO
	model.place("smelter", furnace)
	expect(not model.start_repair(furnace).is_empty() and model.cash == 660, "Healthy repair is rejected without charge")
	seed_materials(model, furnace, "iron_ore", 4, true)
	model.cells[furnace].wear = int(Factory.CATALOG.maintenance.wear_limit) - 2
	run_steps(model, 2)
	expect(model.cells[furnace].progress == 2, "Healthy last two wear ticks retain full speed")
	run_steps(model, 4)
	expect(model.cells[furnace].progress == 4 and model.cells[furnace].status == "degraded", "Worn machine progresses at half speed without destroying inputs")
	model.set_enabled(furnace, false)
	var old_wear: int = model.cells[furnace].wear
	run_steps(model, 10)
	expect(model.cells[furnace].wear == old_wear, "Disabled equipment does not wear")
	model.set_enabled(furnace, true)
	expect(model.start_repair(furnace).is_empty() and model.cash == 620, "Repair charges 40 once")
	expect(not model.start_repair(furnace).is_empty() and model.cash == 620, "Duplicate repair cannot charge again")
	run_steps(model, 50)
	expect(model.cells[furnace].progress == 4 and model.power_used == 0 and model.cells[furnace].repair_remaining == 50, "Repair pauses batch and power consumption")
	var store = SaveStore.new()
	var encoded: Dictionary = store.encode(model)
	expect(not encoded.has("error"), "Save during maintenance")
	if not encoded.has("error"):
		var restored: Dictionary = store.decode(encoded.document)
		expect(not restored.has("error"), "Load maintenance state")
		if not restored.has("error"):
			run_steps(model, 50)
			run_steps(restored.model, 50)
			expect(model.snapshot() == restored.model.snapshot(), "Repair resumes identically after load")
	expect(model.cells[furnace].wear == 0 and model.cells[furnace].progress == 4, "Maintenance completes without consuming in-progress materials")
	run_steps(model, 16)
	expect(model.cells[furnace].produced == 1, "Repaired machine resumes original batch at full speed")
	var recycle = Factory.new(800, true)
	recycle.place("smelter", furnace)
	recycle.cells[furnace].wear = 900
	expect(recycle.remove(furnace).is_empty() and recycle.cash == 800, "Empty worn machine keeps full-price refund")
	var retired_save: Dictionary = store.decode(store.encode(recycle).document)
	expect(not retired_save.has("error") and retired_save.model.snapshot() == recycle.snapshot(), "Retired equipment condition survives save")
	recycle.place("smelter", Vector2i(2, 0))
	expect(recycle.cells[Vector2i(2, 0)].wear == 900, "Rebuilding elsewhere cannot reset wear")
	recycle.start_repair(Vector2i(2, 0))
	expect(not recycle.remove(Vector2i(2, 0)).is_empty() and not recycle.rotate(Vector2i(2, 0)).is_empty(), "Cannot bypass active maintenance by rebuilding")
	var poor = Factory.new(179, true)
	poor.place("smelter", furnace)
	poor.cells[furnace].wear = 1
	expect(not poor.start_repair(furnace).is_empty() and poor.cash == 39 and poor.cells[furnace].repair_remaining == 0, "Unaffordable repair is atomic")
	var powerless = Factory.new(800, true)
	powerless.place("smelter", furnace)
	seed_materials(powerless, furnace, "iron_ore", 1, true)
	powerless.power_capacity = 0
	run_steps(powerless, 10)
	expect(powerless.cells[furnace].wear == 0, "Waiting for power does not wear equipment")
	var full_grid = Factory.new(10000, true)
	full_grid.place("smelter", furnace)
	full_grid.cells[furnace].wear = 900
	full_grid.remove(furnace)
	for row: int in range(Factory.HEIGHT):
		for column: int in range(Factory.WIDTH):
			full_grid.place("belt", Vector2i(column, row))
	expect(not store.encode(full_grid).has("error"), "A full belt grid can retain a removed machine without invalidating the save")


func altered_document(document: String, change: Callable) -> String:
	var envelope: Dictionary = JSON.parse_string(document)
	var body: Dictionary = JSON.parse_string(envelope.payload)
	change.call(body)
	envelope.payload = JSON.stringify(body, "", true, true)
	envelope.sha256 = envelope.payload.sha256_text()
	return JSON.stringify(envelope)


func write_test_file(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	expect(file != null, "Test fixture file can be created")
	if file != null:
		file.store_string(text)
		file.close()


func test_saves() -> void:
	var store = SaveStore.new()
	var model = Fixtures.create("double_limited")
	model.test_sink_enabled = true
	model.advance(47.03)
	model.set_priority(Vector2i(12, 7), 0)
	var encoded: Dictionary = store.encode(model)
	expect(not encoded.has("error"), "Serialize valid factory")
	if encoded.has("error"):
		push_error(str(encoded.error))
		return
	var loaded: Dictionary = store.decode(encoded.document)
	expect(not loaded.has("error"), "Deserialize valid factory")
	if loaded.has("error"):
		push_error(str(loaded.error))
		return
	var restored: Factory = loaded.model
	expect(model.snapshot() == restored.snapshot() and is_equal_approx(model.accumulator, restored.accumulator), "Save restores all simulation state and fractional clock")
	var legacy: Dictionary = JSON.parse_string(encoded.document)
	var old_body: Dictionary = JSON.parse_string(legacy.payload)
	old_body.simulation.erase("wear_enabled")
	old_body.simulation.erase("retired_machines")
	for entry: Dictionary in old_body.simulation.buildings:
		entry.state.erase("wear")
		entry.state.erase("wear_phase")
		entry.state.erase("repair_remaining")
	legacy.version = 1
	legacy.payload = JSON.stringify(old_body, "", true, true)
	legacy.sha256 = legacy.payload.sha256_text()
	var migrated: Dictionary = store.decode(JSON.stringify(legacy))
	expect(not migrated.has("error") and migrated.migrated and not migrated.model.wear_enabled, "Version 1 migrates without enabling new wear rules")
	expect(migrated.model.snapshot() == restored.snapshot(), "Migration preserves old simulation state")
	model.advance(0.07)
	restored.advance(0.07)
	run_steps(model, 500)
	run_steps(restored, 500)
	expect(model.snapshot() == restored.snapshot(), "Resuming matches uninterrupted production and arbitration")
	model.pending_commands.append({"action": "rotate", "cell": Vector2i(0, 0)})
	expect(store.encode(model).has("error"), "Uncommitted commands cannot be silently lost on save")
	model.pending_commands.clear()
	expect(store.decode("{broken").has("error"), "Reject malformed JSON")
	var envelope: Dictionary = JSON.parse_string(encoded.document)
	envelope.sha256 = "incorrect"
	expect(store.decode(JSON.stringify(envelope)).has("error"), "Reject checksum corruption")
	envelope = JSON.parse_string(encoded.document)
	envelope.version = 999
	expect(store.decode(JSON.stringify(envelope)).get("unsupported", false), "Reject future schema without fallback downgrade")
	for change: Callable in [
		func(body: Dictionary) -> void: body.simulation.buildings[0].state.kind = "unknown",
		func(body: Dictionary) -> void: body.simulation.buildings.append(body.simulation.buildings[0].duplicate(true)),
		func(body: Dictionary) -> void: body.simulation.cash = -1,
		func(body: Dictionary) -> void: body.simulation.supplied += 1,
		func(body: Dictionary) -> void: body.simulation.buildings[0].state.facing = 9,
		func(body: Dictionary) -> void: body.simulation.contracts = "yes",
		func(body: Dictionary) -> void: body.simulation.power_cursors = [999, 0, 0],
		func(body: Dictionary) -> void: body.simulation.buildings[0].state.wear = 5000,
		func(body: Dictionary) -> void: body.simulation.buildings[0].state.repair_remaining = 9999,
	]:
		expect(store.decode(altered_document(encoded.document, change)).has("error"), "Reject invalid data even with recomputed checksum")
	var prefix: String = "user://tests/save-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(prefix))
	var path: String = prefix + "/factory.json"
	var first: Dictionary = model.snapshot()
	expect(not store.save_game(model, path).has("error"), "Write first save")
	model.advance(2.0)
	var refusing = RefusingSaveStore.new()
	expect(refusing.save_game(model, path).has("error"), "Simulated filesystem replacement failure is reported")
	var after_failure: Dictionary = store.load_game(path)
	expect(not after_failure.has("error") and after_failure.model.snapshot() == first, "Write failure retains old primary")
	expect(not store.save_game(model, path).has("error"), "Write second save and retain backup")
	var second: Dictionary = store.load_game(path)
	expect(not second.has("error") and second.model.snapshot() == model.snapshot(), "Read latest primary")
	write_test_file(path, "{broken")
	var recovered: Dictionary = store.load_game(path)
	expect(not recovered.has("error") and recovered.recovered and recovered.model.snapshot() == first, "Corrupt primary falls back to verified backup")
	expect(not store.save_game(model, path).has("error"), "Saving after recovery does not overwrite good backup with corrupt data")
	expect(store.load_game(path + ".bak").model.snapshot() == first, "Good backup remains after recovery save")
	write_test_file(path, JSON.stringify(envelope))
	expect(store.load_game(path).get("unsupported", false), "Future primary is not silently replaced with old backup")
	expect(store.save_game(model, path).has("error"), "Cannot overwrite future version")
	var blocker: String = prefix + "/blocker"
	write_test_file(blocker, "not a directory")
	expect(store.save_game(model, blocker + "/save.json").has("error"), "Directory creation failure is reported")
	for filename: String in [path, path + ".bak", blocker]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(filename))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prefix))