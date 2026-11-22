extends RefCounted

const Worker = preload("res://simulation/worker.gd")

const SIZE := Vector2i(13, 9)
const WALL_COLUMN: int = 6
const HQ_CELLS := [Vector2i(2, 4), Vector2i(10, 4)]
const ORE_CELLS := [Vector2i(4, 2), Vector2i(8, 2)]
const STARTING_ORE: int = 18
const WORKER_START := Vector2i(3, 4)
const PLAYER: int = 0
const ROBOT_ID: String = "worker_0"
const FRIENDLY_ORE_ID: String = "ore_0"
const NEIGHBOR_OFFSETS := [Vector2i.RIGHT, Vector2i.UP, Vector2i.LEFT, Vector2i.DOWN]

var tick: int = 0
var worker := Worker.new(WORKER_START)
var stored_ore: Array[int] = [0, 0]
var ore_remaining: Array[int] = [STARTING_ORE, STARTING_ORE]
var last_action: String = "Idle"

var _decide_action: Callable


func _init(decide_action: Callable = Callable()) -> void:
	_decide_action = decide_action


# A tick observes the previous state, resolves one request, then publishes the result.
func step_tick() -> void:
	step_with_action(_decide_action.call(observe_worker()))


func step_with_action(requested_action: Dictionary) -> void:
	last_action = _resolve_action(requested_action)
	tick += 1


func observe_worker() -> Dictionary:
	var neighbors: Array[Vector2i] = []
	for offset: Vector2i in NEIGHBOR_OFFSETS:
		var neighbor := worker.cell + offset
		if _is_open(neighbor):
			neighbors.append(neighbor)
	return {
		"cell": worker.cell,
		"walkable_neighbors": neighbors,
		"hq_cell": HQ_CELLS[PLAYER],
		"ore_cell": ORE_CELLS[PLAYER],
		"ore_remaining": ore_remaining[PLAYER],
		"ore_id": FRIENDLY_ORE_ID,
		"carried_ore": worker.carried_ore,
		"capacity": Worker.CAPACITY,
		"last_action": last_action,
		"mining_ticks": worker.mining_ticks,
		"mining_ticks_required": Worker.TICKS_PER_ORE,
	}


func _resolve_action(action: Dictionary) -> String:
	var kind: Variant = action.get("kind")
	if kind is int and kind == Worker.Action.MINE and _can_mine(action.get("deposit_id", FRIENDLY_ORE_ID)):
		ore_remaining[PLAYER] -= worker.mine_one_tick()
		return "Mining"

	# An interrupted or rejected mining action loses its partial progress.
	worker.mining_ticks = 0
	match kind:
		Worker.Action.WAIT:
			return "Idle"
		Worker.Action.MOVE:
			var destination: Variant = action.get("target")
			if destination is Vector2i:
				if _are_adjacent(worker.cell, destination) and _is_open(destination):
					worker.move_to(destination)
					return "Moving"
		Worker.Action.DEPOSIT:
			if worker.carried_ore > 0 and _are_adjacent(worker.cell, HQ_CELLS[PLAYER]):
				stored_ore[PLAYER] += worker.unload_ore()
				return "Depositing"
	return "Rejected"


func _can_mine(deposit_id: Variant) -> bool:
	return (
		deposit_id is String and deposit_id == FRIENDLY_ORE_ID
		and worker.can_carry_ore() and ore_remaining[PLAYER] > 0
		and _are_adjacent(worker.cell, ORE_CELLS[PLAYER])
	)


func _is_open(cell: Vector2i) -> bool:
	var deposit_index := ORE_CELLS.find(cell)
	return (
		Rect2i(Vector2i.ZERO, SIZE).has_point(cell)
		and cell.x != WALL_COLUMN
		and cell not in HQ_CELLS
		and (deposit_index == -1 or ore_remaining[deposit_index] == 0)
		and cell != worker.cell
	)


func _are_adjacent(first: Vector2i, second: Vector2i) -> bool:
	var difference := first - second
	return absi(difference.x) + absi(difference.y) == 1
