extends RefCounted

enum Action { WAIT, MOVE, MINE, DEPOSIT }

# Prototype values. The simulation checks where each capability may be used.
const CAPACITY: int = 3
const TICKS_PER_ORE: int = 3

var cell: Vector2i
var carried_ore: int = 0
var mining_ticks: int = 0


func _init(start_cell: Vector2i) -> void:
	cell = start_cell


func move_to(destination: Vector2i) -> void:
	cell = destination


func can_carry_ore() -> bool:
	return carried_ore < CAPACITY


func mine_one_tick() -> int:
	mining_ticks += 1
	if mining_ticks < TICKS_PER_ORE:
		return 0
	mining_ticks = 0
	carried_ore += 1
	return 1


func unload_ore() -> int:
	var amount := carried_ore
	carried_ore = 0
	return amount
