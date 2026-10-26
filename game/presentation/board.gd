extends Control

signal cell_pressed(cell: Vector2i, mouse_button: int)

const Factory = preload("res://simulation/factory.gd")
const ATLAS = preload("res://assets/factory_tiles.svg")
const TILE_INDEX: Dictionary = {"source": 0, "belt": 1, "splitter": 2, "smelter": 3, "press": 4, "storage": 5, "delivery": 6}
const ITEM_COLOR: Dictionary = {"iron_ore": Color("d5b86c"), "iron_plate": Color("b6d3df"), "component": Color("87cca9")}
const SIDE_NAMES: Array[String] = ["East", "South", "West", "North"]

var model: Factory
var tool: String = "inspect"
var facing: int = 0
var selected := Vector2i(-1, -1)
var hovered := Vector2i(-1, -1)
var last_drag := Vector2i(-1, -1)
var show_starter_layout: bool = true


func _ready() -> void:
	custom_minimum_size = Vector2(480, 320)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	mouse_exited.connect(func() -> void:
		hovered = Vector2i(-1, -1)
		tooltip_text = ""
		queue_redraw())


func cell_size() -> float:
	return floorf(minf((size.x - 24.0) / Factory.WIDTH, (size.y - 32.0) / Factory.HEIGHT))


func grid_origin() -> Vector2:
	return (size - Vector2(Factory.WIDTH, Factory.HEIGHT) * cell_size()) * 0.5


func cell_center(cell: Vector2i) -> Vector2:
	return grid_origin() + (Vector2(cell) + Vector2(0.5, 0.5)) * cell_size()


func _cell_at(point: Vector2) -> Vector2i:
	var local: Vector2 = (point - grid_origin()) / maxf(cell_size(), 1.0)
	return Vector2i(floori(local.x), floori(local.y))


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < Factory.WIDTH and cell.y < Factory.HEIGHT


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		hovered = _cell_at(event.position)
		_update_tooltip()
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT and _in_bounds(hovered) and hovered != last_drag:
			last_drag = hovered
			cell_pressed.emit(hovered, MOUSE_BUTTON_LEFT)
		queue_redraw()
	elif event is InputEventMouseButton:
		if not event.pressed:
			last_drag = Vector2i(-1, -1)
			return
		hovered = _cell_at(event.position)
		if _in_bounds(hovered):
			last_drag = hovered
			cell_pressed.emit(hovered, event.button_index)
			_update_tooltip()
			accept_event()


func visible_plan() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if model == null or not show_starter_layout or not model.contracts_enabled or model.order_index != 0:
		return entries
	for entry: Dictionary in Factory.CATALOG.starter_layout:
		if not model.cells.has(entry.cell):
			entries.append(entry)
	return entries


func _update_tooltip() -> void:
	tooltip_text = ""
	if model == null or not _in_bounds(hovered):
		return
	if not model.cells.has(hovered):
		if tool != "inspect":
			var error: String = model.placement_error(tool, hovered, facing)
			tooltip_text = "%s / %d credits / %s" % [tool.capitalize(), Factory.CATALOG.buildings[tool].price, SIDE_NAMES[facing]]
			if not error.is_empty():
				tooltip_text += "\n" + error
		elif hovered == Vector2i(2, 7):
			tooltip_text = "Iron ore inlet (2, 7)"
		for entry: Dictionary in visible_plan():
			if entry.cell == hovered:
				if not tooltip_text.is_empty():
					tooltip_text += "\n"
				tooltip_text += "O1 layout: %s / %s / %d credits" % [entry.kind.capitalize(), SIDE_NAMES[entry.facing], Factory.CATALOG.buildings[entry.kind].price]
		return
	var building: Dictionary = model.cells[hovered]
	tooltip_text = "%s (%d, %d)\n%s\nInput %d | Output %d" % [building.kind.capitalize(), hovered.x, hovered.y, building.status, building.input.size(), building.output.size()]
	for side: int in range(4):
		var items: Array[String] = model.input_items(building, side)
		if not items.is_empty():
			tooltip_text += "\n%s input: %s" % [SIDE_NAMES[side], ", ".join(items).replace("_", " ")]
	for side: int in model.output_sides(building):
		tooltip_text += "\n%s output" % SIDE_NAMES[side]


func _draw_ports(building: Dictionary, cell: Vector2i) -> void:
	var reach: float = cell_size() * 0.5 - 2.0
	for side: int in range(4):
		var outgoing: bool = side in model.output_sides(building)
		if not outgoing and model.input_items(building, side).is_empty():
			continue
		var direction := Vector2(Factory.DIRECTIONS[side])
		var tangent := Vector2(-direction.y, direction.x)
		var tip: Vector2 = cell_center(cell) + direction * (reach if outgoing else reach - 4.0)
		var base: Vector2 = cell_center(cell) + direction * (reach - 4.0 if outgoing else reach)
		var points := PackedVector2Array([base + tangent * 3.0, tip, base - tangent * 3.0])
		if outgoing:
			draw_colored_polygon(points, Color("eadb93"))
		else:
			draw_polyline(points, Color("98d4e3"), 1.5)


func _draw_tile(kind: String, cell: Vector2i, direction: int, tint: Color = Color.WHITE) -> void:
	var extent: float = cell_size() - 6.0
	draw_set_transform(cell_center(cell), direction * PI / 2.0)
	draw_texture_rect_region(ATLAS, Rect2(Vector2(-extent, -extent) * 0.5, Vector2(extent, extent)), Rect2(int(TILE_INDEX[kind]) * 32, 0, 32, 32), tint)
	draw_set_transform(Vector2.ZERO)


func _draw() -> void:
	if model == null or cell_size() <= 0.0:
		return
	var tile_size: float = cell_size()
	var origin: Vector2 = grid_origin()
	var span := Vector2(Factory.WIDTH, Factory.HEIGHT) * tile_size
	draw_rect(Rect2(Vector2.ZERO, size), Color("171c1d"))
	for row: int in range(Factory.HEIGHT):
		for column: int in range(Factory.WIDTH):
			var shade := Color("202627") if (row + column) % 2 == 0 else Color("222829")
			draw_rect(Rect2(origin + Vector2(column, row) * tile_size, Vector2.ONE * tile_size), shade)
	for column: int in range(Factory.WIDTH + 1):
		draw_line(origin + Vector2(column * tile_size, 0), origin + Vector2(column * tile_size, span.y), Color("32393a"))
	for row: int in range(Factory.HEIGHT + 1):
		draw_line(origin + Vector2(0, row * tile_size), origin + Vector2(span.x, row * tile_size), Color("32393a"))
	var font: Font = get_theme_default_font()
	for column: int in range(0, Factory.WIDTH, 4):
		draw_string(font, origin + Vector2(column * tile_size + 3, -5), str(column), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("8c9b96"))
	for entry: Dictionary in visible_plan():
		_draw_tile(entry.kind, entry.cell, entry.facing, Color(0.72, 0.87, 0.94, 0.3))
		var corner: Vector2 = origin + Vector2(entry.cell) * tile_size
		var plan_color := Color("617e87")
		for offset: Vector2 in [Vector2(3, 3), Vector2(tile_size - 3, 3), Vector2(3, tile_size - 3), Vector2(tile_size - 3, tile_size - 3)]:
			var inward := Vector2(1 if offset.x < tile_size * 0.5 else -1, 1 if offset.y < tile_size * 0.5 else -1)
			draw_line(corner + offset, corner + offset + Vector2(inward.x * 4, 0), plan_color)
			draw_line(corner + offset, corner + offset + Vector2(0, inward.y * 4), plan_color)
	for cell: Vector2i in model.ordered_cells():
		var building: Dictionary = model.cells[cell]
		var tint := Color.WHITE if building.enabled else Color(0.5, 0.5, 0.5, 1.0)
		_draw_tile(building.kind, cell, int(building.facing), tint)
		if cell == selected or cell == hovered:
			_draw_ports(building, cell)
		var corner: Vector2 = origin + Vector2(cell) * tile_size
		if building.repair_remaining > 0:
			draw_texture_rect_region(ATLAS, Rect2(corner + Vector2(1, 1), Vector2(12, 12)), Rect2(480, 0, 32, 32))
		elif building.status == "output blocked":
			draw_rect(Rect2(corner + Vector2(2, 2), Vector2(5, 5)), Color("ed8c76"))
		elif building.status == "no power":
			draw_texture_rect_region(ATLAS, Rect2(corner + Vector2(1, 1), Vector2(12, 12)), Rect2(384, 0, 32, 32))
		elif building.status == "missing input":
			draw_rect(Rect2(corner + Vector2(2, 2), Vector2(5, 5)), Color("e0c476"))
		if model.wear_enabled and building.wear >= int(Factory.CATALOG.maintenance.warning_at):
			var wear_color := Color("ed8c76") if building.wear >= int(Factory.CATALOG.maintenance.wear_limit) else Color("e0c476")
			draw_rect(Rect2(corner + Vector2(2, tile_size - 2), Vector2(tile_size - 4, 2)), wear_color)
		if building.active:
			var ratio: float = float(building.progress) / float(model.recipe_for(building).ticks)
			draw_rect(Rect2(corner + Vector2(3, tile_size - 4), Vector2((tile_size - 6) * ratio, 2)), Color("a9dec0"))
		for index: int in range(mini(building.output.size(), 2)):
			var packet: Dictionary = building.output[index]
			draw_rect(Rect2(corner + Vector2(4 + index * 7, tile_size - 10), Vector2(5, 5)), ITEM_COLOR[packet.item])
	if not model.cells.has(Vector2i(2, 7)):
		draw_rect(Rect2(origin + Vector2(2, 7) * tile_size + Vector2(3, 3), Vector2.ONE * (tile_size - 6)), Color("6b9c88"), false, 2)
	if _in_bounds(selected):
		draw_rect(Rect2(origin + Vector2(selected) * tile_size + Vector2.ONE, Vector2.ONE * (tile_size - 2)), Color("ecf1e5"), false, 2)
	if _in_bounds(hovered):
		var color := Color("a8d8ba")
		if tool != "inspect":
			if not model.placement_error(tool, hovered, facing).is_empty():
				color = Color("ed8c76")
			var ghost: Color = color
			ghost.a = 0.45
			_draw_tile(tool, hovered, facing, ghost)
			if not model.cells.has(hovered):
				_draw_ports({"kind": tool, "facing": facing, "storage_item": "iron_ore"}, hovered)
		draw_rect(Rect2(origin + Vector2(hovered) * tile_size + Vector2.ONE, Vector2.ONE * (tile_size - 2)), color, false)