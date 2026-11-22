extends RefCounted

const Worker = preload("res://simulation/worker.gd")


static func observation(snapshot: Dictionary) -> Dictionary:
	var neighbors: Array = []
	for cell: Vector2i in snapshot.walkable_neighbors:
		neighbors.append(_coordinates(cell))
	return {
		"position": _coordinates(snapshot.cell),
		"walkable_neighbors": neighbors,
		"hq_position": _coordinates(snapshot.hq_cell),
		"ore_deposits": [{
			"id": snapshot.ore_id,
			"position": _coordinates(snapshot.ore_cell),
			"remaining": snapshot.ore_remaining,
		}],
		"carried_ore": snapshot.carried_ore,
		"capacity": snapshot.capacity,
		"last_action": snapshot.last_action.to_lower(),
		"mining_ticks": snapshot.mining_ticks,
		"mining_ticks_required": snapshot.mining_ticks_required,
	}


static func action_request(action: Variant) -> Dictionary:
	if action is Dictionary:
		match action.get("kind"):
			"idle":
				return {"kind": Worker.Action.WAIT}
			"deposit":
				return {"kind": Worker.Action.DEPOSIT}
			"mine":
				return {"kind": Worker.Action.MINE, "deposit_id": action.get("deposit_id")}
			"move_to":
				var target: Variant = action.get("target")
				if target is Array and target.size() == 2 and _is_grid_int(target[0]) and _is_grid_int(target[1]):
					return {"kind": Worker.Action.MOVE, "target": Vector2i(int(target[0]), int(target[1]))}
	return {} # The simulation records a rejected action.


static func _coordinates(cell: Vector2i) -> Array[int]:
	return [cell.x, cell.y]


static func _is_grid_int(value: Variant) -> bool:
	return (value is int or value is float) and absf(float(value)) <= 2147483647.0 and floor(value) == value
