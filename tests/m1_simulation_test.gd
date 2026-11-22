extends SceneTree

const Simulation = preload("res://simulation/arena_simulation.gd")
const Worker = preload("res://simulation/worker.gd")
const Behavior = preload("res://simulation/worker_behavior.gd")

var _failures: int = 0
var _request: Dictionary


func _initialize() -> void:
	_test_autonomous_cycles()
	_test_invalid_requests()
	_test_depletion()
	print("M1 simulation checks passed" if _failures == 0 else "M1 failures: %d" % _failures)
	quit(0 if _failures == 0 else 1)


func _test_autonomous_cycles() -> void:
	var simulation := Simulation.new(Behavior.decide)
	var snapshots: Array[String] = [_snapshot(simulation)]
	var deposit_ticks: Array[int] = []
	for expected_tick in range(1, 101):
		var previous_stored := simulation.stored_ore[0]
		simulation.step_tick()
		_expect(simulation.tick == expected_tick, "step_tick advances exactly once")
		_expect(simulation.worker.cell.x < Simulation.WALL_COLUMN, "worker stays on its side")
		_expect(simulation.worker.carried_ore <= Worker.CAPACITY, "worker stays within capacity")
		_expect_conserved_ore(simulation)
		if simulation.stored_ore[0] != previous_stored:
			_expect(simulation.stored_ore[0] == previous_stored + 3, "deposit transfers 3 Ore")
			_expect(simulation.worker.carried_ore == 0, "deposit empties inventory")
			deposit_ticks.append(expected_tick)
		snapshots.append(_snapshot(simulation))

	_expect(deposit_ticks == [14, 28, 42, 56, 70, 84], "six complete cycles on expected ticks")
	_expect(simulation.stored_ore == [18, 0], "all 18 player Ore reach the player HQ")
	_expect(simulation.ore_remaining == [0, 18], "opponent Ore stays untouched")
	_expect(simulation.last_action == "Idle", "worker idles after delivering the last Ore")
	print("M1 deposits at ticks %s" % str(deposit_ticks))
	print("M1 final state %s" % snapshots.back())
	print("M1 state trace ticks 0–100 SHA-256 %s" % "\n".join(snapshots).sha256_text())


func _test_invalid_requests() -> void:
	var simulation := Simulation.new(_decide_requested_action)
	_expect_action(simulation, Worker.Action.MINE, "Rejected")
	_expect_action(simulation, Worker.Action.DEPOSIT, "Rejected")
	_expect_move(simulation, Vector2i(2, 4), false) # Occupied by HQ.
	_expect_move(simulation, Vector2i(4, 3), false) # Diagonal from spawn.
	_expect_move(simulation, Vector2i(7, 4), false) # Jump across the wall.
	_expect_move(simulation, Vector2i(4, 4), true)
	_expect_move(simulation, Vector2i(5, 4), true)
	_expect_move(simulation, Vector2i(6, 4), false) # Adjacent wall cell.
	for y in range(5, Simulation.SIZE.y):
		_expect_move(simulation, Vector2i(5, y), true)
		_expect_move(simulation, Vector2i(6, y), false)
	for y in range(Simulation.SIZE.y - 2, -1, -1):
		_expect_move(simulation, Vector2i(5, y), true)
		_expect_move(simulation, Vector2i(6, y), false)
	_expect_move(simulation, Vector2i(5, -1), false) # Outside the arena.
	_expect_move(simulation, Vector2i(4, 0), true)
	_expect_move(simulation, Vector2i(4, 1), true)
	_expect_move(simulation, Vector2i(4, 2), false) # Occupied by Ore.

	_expect_action(simulation, Worker.Action.MINE, "Mining")
	_expect(simulation.worker.mining_ticks == 1, "first mining tick records partial progress")
	_expect_action(simulation, Worker.Action.WAIT, "Idle")
	_expect(simulation.worker.mining_ticks == 0, "waiting interrupts mining")
	for mining_tick in range(1, 10):
		_expect_action(simulation, Worker.Action.MINE, "Mining")
		var expected_ore := floori(mining_tick / 3.0)
		_expect(simulation.worker.carried_ore == expected_ore, "one Ore per three mining ticks")
		_expect(simulation.ore_remaining[0] == 18 - expected_ore, "mining debits the deposit")
	_expect_action(simulation, Worker.Action.MINE, "Rejected")
	_expect_action(simulation, Worker.Action.DEPOSIT, "Rejected") # Away from HQ.
	_expect(simulation.stored_ore[0] == 0, "failed deposit does not credit HQ")
	_expect(simulation.worker.carried_ore == 3, "rejected actions leave the full inventory intact")
	_expect_conserved_ore(simulation)


func _test_depletion() -> void:
	var simulation := Simulation.new(_decide_requested_action)
	simulation.ore_remaining[0] = 1
	_expect_move(simulation, Vector2i(4, 4), true)
	_expect_move(simulation, Vector2i(4, 3), true)
	for _mining_tick in range(Worker.TICKS_PER_ORE):
		_expect_action(simulation, Worker.Action.MINE, "Mining")
	_expect_action(simulation, Worker.Action.MINE, "Rejected")
	_expect(simulation.worker.carried_ore == 1 and simulation.ore_remaining[0] == 0,
		"a depleted deposit cannot create Ore")

	# The preset must return a partial load when there is nothing left to mine.
	var preset_simulation := Simulation.new(Behavior.decide)
	preset_simulation.ore_remaining[0] = 1
	for _tick_number in range(10):
		preset_simulation.step_tick()
	_expect(preset_simulation.stored_ore[0] == 1 and preset_simulation.worker.carried_ore == 0,
		"the preset deposits the final partial load")


func _decide_requested_action(_observation: Dictionary) -> Dictionary:
	return _request


func _expect_move(simulation: Simulation, target: Vector2i, allowed: bool) -> void:
	var start := simulation.worker.cell
	_request = {"kind": Worker.Action.MOVE, "target": target}
	simulation.step_tick()
	_expect(simulation.worker.cell == (target if allowed else start), "move to %s" % str(target))
	_expect(simulation.last_action == ("Moving" if allowed else "Rejected"), "move result")


func _expect_action(simulation: Simulation, kind: int, expected: String) -> void:
	_request = {"kind": kind}
	simulation.step_tick()
	_expect(simulation.last_action == expected, "action %d should be %s" % [kind, expected])


func _expect_conserved_ore(simulation: Simulation) -> void:
	var total := simulation.ore_remaining[0] + simulation.worker.carried_ore + simulation.stored_ore[0]
	_expect(total == Simulation.STARTING_ORE, "Ore is conserved across all three stores")


func _snapshot(simulation: Simulation) -> String:
	return JSON.stringify([
		simulation.tick,
		simulation.worker.cell.x,
		simulation.worker.cell.y,
		simulation.worker.carried_ore,
		simulation.worker.mining_ticks,
		simulation.stored_ore,
		simulation.ore_remaining,
		simulation.last_action,
	])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)
