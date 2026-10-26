extends RefCounted

const Factory = preload("res://simulation/factory.gd")


static func create(mode: String = "plate") -> Factory:
	var expanded: bool = mode in ["double", "double_limited", "maintenance"]
	var model = Factory.new(1000 if expanded else 800, mode == "contract")
	if mode in ["double_limited", "maintenance"]:
		model.unlimited_power = false
	if mode == "maintenance":
		model.wear_enabled = true
	if mode in ["empty", "contract"]:
		return model
	for entry: Dictionary in Factory.CATALOG.starter_layout:
		model.place(entry.kind, entry.cell, entry.facing)
	if mode != "plate":
		model.remove(Vector2i(12, 7))
		model.place("press", Vector2i(12, 7))
	if expanded:
		model.remove(Vector2i(3, 7))
		model.place("splitter", Vector2i(3, 7))
		model.place("smelter", Vector2i(6, 10))
		for entry: Array in [
			[3, 8, 1], [3, 9, 1], [3, 10, 0], [4, 10, 0], [5, 10, 0],
			[7, 10, 0], [8, 10, 0], [9, 10, 3], [9, 9, 3], [9, 8, 3],
		]:
			model.place("belt", Vector2i(entry[0], entry[1]), entry[2])
	if mode == "maintenance":
		model.cells[Vector2i(6, 7)].wear = int(Factory.CATALOG.maintenance.wear_limit)
		model.cells[Vector2i(12, 7)].wear = int(Factory.CATALOG.maintenance.warning_at)
	return model