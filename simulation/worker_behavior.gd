extends RefCounted

const Worker = preload("res://simulation/worker.gd")


# Takes a fresh observation and returns one request. Holds no world references.
static func decide(observation: Dictionary) -> Dictionary:
	var cell: Vector2i = observation.cell
	var carried: int = observation.carried_ore
	var deposit_run: bool = carried == observation.capacity or observation.ore_remaining == 0
	if deposit_run and carried == 0:
		return {"kind": Worker.Action.WAIT}

	var target: Vector2i = observation.hq_cell if deposit_run else observation.ore_cell
	var distance := _distance(cell, target)
	if distance == 1:
		return {"kind": Worker.Action.DEPOSIT if deposit_run else Worker.Action.MINE}

	# Neighbor order breaks ties. The fixed arena has a direct route to each target.
	for neighbor: Vector2i in observation.walkable_neighbors:
		if _distance(neighbor, target) < distance:
			return {"kind": Worker.Action.MOVE, "target": neighbor}
	return {"kind": Worker.Action.WAIT}


static func _distance(from: Vector2i, to: Vector2i) -> int:
	return absi(from.x - to.x) + absi(from.y - to.y)
