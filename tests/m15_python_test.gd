extends SceneTree

const Arena = preload("res://scenes/arena.gd")
const ArenaScene = preload("res://scenes/arena.tscn")
const Simulation = preload("res://simulation/arena_simulation.gd")
const Bridge = preload("res://python_bridge/python_bridge.gd")

var _failures: int = 0
var _files: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var first := await _worker_trace()
	var second := await _worker_trace()
	_expect(first.size() == 101 and first == second, "C: Both Python runs match at ticks 0–100")
	if first.size() == 101 and first == second:
		print("C: Identical state trace through tick 100: %s" % "\n".join(first).sha256_text())
	await _test_idle_policy()
	await _test_syntax_failure()
	await _test_runtime_exception()
	await _test_invalid_actions()
	await _test_invalid_frames_and_late_reply()
	await _test_process_failure(false)
	await _test_process_failure(true)
	for path in _files:
		DirAccess.remove_absolute(path)
	print("M1.5 Python checks passed" if _failures == 0 else "M1.5 failures: %d" % _failures)
	quit(0 if _failures == 0 else 1)


func _worker_trace() -> Array[String]:
	var arena := _spawn("res://python/worker.py")
	var sim := arena._simulation
	var history: Array[String] = [_snapshot(sim)]
	var deposits: Array[int] = []
	for tick_id in range(1, 101):
		var ore_before := sim.stored_ore[0]
		if not await _step_after_reply(arena):
			break
		if sim.stored_ore[0] > ore_before:
			deposits.append(sim.tick)
			_expect(sim.stored_ore[0] == ore_before + 3 and sim.worker.carried_ore == 0,
				"A: Deposit transfers one full inventory")
		if tick_id == 1:
			_expect(sim.worker.cell == Vector2i(4, 4) and sim.last_action == "Moving", "A: Move toward Ore")
		if tick_id == 3:
			_expect(sim.worker.mining_ticks == 1 and sim.last_action == "Mining", "A: Start timed mining")
		if tick_id == 5:
			_expect(sim.worker.carried_ore == 1 and sim.ore_remaining[0] == 17, "A: Carry Ore after three mining ticks")
		if tick_id == 13:
			_expect(sim.worker.cell == Vector2i(2, 3) and sim.worker.carried_ore == 3, "A: Return to HQ with Ore")
		history.append(_snapshot(sim))
	_expect(deposits == [14, 28, 42, 56, 70, 84], "A: Six complete deposits")
	_expect(sim.stored_ore == [18, 0] and sim.ore_remaining == [0, 18], "A: Correct final resource totals")
	_expect(arena._python.last_error.is_empty(), "A: No bridge errors in a normal run")
	print("A: Deposits at %s; HQ Ore %d" % [str(deposits), sim.stored_ore[0]])
	arena.free()
	return history


func _test_idle_policy() -> void:
	var path := _fixture("idle", """
print("Ordinary behavior output goes to stderr")
def on_tick(observation):
    assert observation["tick_id"] > 0 and observation["robot_id"] == "worker_0"
    assert [ore["id"] for ore in observation["ore_deposits"]] == ["ore_0"]
    return {"kind": "idle"}
""")
	var arena := _spawn(path)
	for _i in range(5):
		if not await _step_after_reply(arena):
			break
	_expect(arena._simulation.tick == 5 and _at_spawn_without_ore(arena), "B: An idle Python policy stays at spawn")
	_expect(arena._simulation.last_action == "Idle" and arena._python.last_error.is_empty(),
		"B: Idle is a valid decision and stdout logging does not break the protocol")
	print("B: Idle policy stayed at spawn with zero Ore after five ticks")
	arena.free()


func _test_syntax_failure() -> void:
	var arena := _spawn(_fixture("syntax", "def on_tick(observation)\n    return {}\n"), false)
	_expect(await _until(func() -> bool: return arena._simulation.tick >= 2), "D: Ticks continue after syntax error")
	_expect(arena._python.status == Bridge.OFFLINE and "SyntaxError" in arena._python.last_error,
		"D: Syntax error puts the Python bridge offline with a diagnostic")
	_expect(_at_spawn_without_ore(arena) and arena.get_node("%PythonError").visible,
		"D: Worker remains idle and the startup error is shown")
	print("D: %s" % arena._python.last_error)
	arena.free()


func _test_runtime_exception() -> void:
	var arena := _spawn(_fixture("exception", """
def on_tick(observation):
    if observation["tick_id"] == 1:
        raise RuntimeError("fixture decision failed")
    return {"kind": "move_to", "target": [4, 4]}
"""))
	if await _step_after_reply(arena):
		_expect(_at_spawn_without_ore(arena), "E: Exception idles the worker")
		_expect("RuntimeError: fixture decision failed" in arena._python.last_error, "E: Readable runtime error")
	if await _step_after_reply(arena):
		_expect(arena._simulation.worker.cell == Vector2i(4, 4) and arena._python.status == Bridge.CONNECTED,
			"E: Same runner can decide successfully on the next tick")
	print("E: %s; subsequent Python move accepted" % arena._python.last_error)
	arena.free()


func _test_invalid_actions() -> void:
	var arena := _spawn(_fixture("invalid", """
def on_tick(observation):
    return [
        {"kind": "teleport"},
        {"kind": "move_to", "target": [7, 4]},
        {"kind": "move_to", "target": [4, 4]},
        {"kind": "move_to", "target": [4, 3]},
        {"kind": "mine", "deposit_id": "ore_1"},
        {"kind": "mine"},
        {"kind": "mine", "deposit_id": "ore_0"},
    ][observation["tick_id"] - 1]
"""))
	var expected_actions := ["Rejected", "Rejected", "Moving", "Moving", "Rejected", "Rejected", "Mining"]
	var sim := arena._simulation
	for expected in expected_actions:
		var previous := sim.worker.cell
		if not await _step_after_reply(arena):
			break
		_expect(sim.last_action == expected, "F: Resolver result is %s on tick %d" % [expected, sim.tick])
		if expected == "Rejected":
			_expect(sim.worker.cell == previous and sim.ore_remaining == [18, 18] and sim.stored_ore == [0, 0]
				and sim.worker.carried_ore == 0, "F: Rejection preserves position and balances")
	_expect("Godot rejected" in arena._python.last_error and sim.worker.mining_ticks == 1,
		"F: Rejections are reported and a valid target can still be mined")
	print("F: Unknown, unreachable, wrong-deposit, and missing-deposit requests rejected")
	arena.free()


func _test_invalid_frames_and_late_reply() -> void:
	var runner := _fixture("protocol", """
import json
import sys

def send(header, **changes):
    print(json.dumps(header | changes), flush=True)

send({"type": "ready"})
for line in sys.stdin:
    request = json.loads(line)
    tick = request["tick_id"]
    reply = {"type": "decision", "tick_id": tick, "robot_id": request["robot_id"],
             "action": {"kind": "move_to", "target": [4, 4]}}
    if tick == 1:
        print("{malformed", flush=True)
        send(reply, type="unknown")
        send(reply, tick_id=2)
        send(reply, robot_id="wrong_robot")
        send(reply, action={"kind": "idle"})
    send(reply)
""")
	var bridge := Bridge.new()
	bridge.start(runner, "res://python/worker.py", 2000)
	if await _until(func() -> bool:
		bridge.poll()
		return bridge.can_request()
	):
		bridge.request_decision(1, Simulation.ROBOT_ID, {})
		_expect(await _until(func() -> bool:
			bridge.poll()
			return "duplicate" in bridge.last_error
		), "Protocol: duplicate detected")
		var first := bridge.take_reply(1, Simulation.ROBOT_ID)
		_expect(not first.is_empty() and first.action.kind == "idle",
			"Protocol: only the first correctly tagged response is accepted")
		bridge.request_decision(2, Simulation.ROBOT_ID, {})
		_expect(bridge.take_reply(2, Simulation.ROBOT_ID).is_empty(), "Protocol: an unanswered tick idles")
		_expect(await _until(func() -> bool:
			bridge.poll()
			return bridge.can_request()
		), "Protocol: late reply is discarded, releasing the pending slot")
		_expect("late Python reply" in bridge.last_error and not bridge.has_reply(2, Simulation.ROBOT_ID),
			"Protocol: a late response cannot reach the simulation")
		bridge.request_decision(3, Simulation.ROBOT_ID, {})
		_expect(await _until(func() -> bool:
			bridge.poll()
			return bridge.has_reply(3, Simulation.ROBOT_ID)
		), "Protocol: next correctly tagged reply is accepted")
	else:
		_expect(false, "Protocol fixture could not start: %s" % bridge.last_error)
	print("Protocol: malformed, unexpected, mismatched, duplicate, and late frames exercised")
	bridge.close()


func _test_process_failure(stall: bool) -> void:
	var source := "import os\ndef on_tick(observation):\n    os._exit(13)\n"
	if stall:
		source = "import time\ndef on_tick(observation):\n    time.sleep(30)\n"
	var arena := _spawn(_fixture("stall" if stall else "exit", source), false, 1000)
	var initial_frames := Engine.get_process_frames()
	var pid := arena._python._pid
	_expect(await _until(func() -> bool:
		return arena._python.status == Bridge.OFFLINE and arena._simulation.tick >= 2
	), "G: Arena stays responsive and ticks continue with runner offline")
	_expect(Engine.get_process_frames() > initial_frames + 5 and _at_spawn_without_ore(arena),
		"G: Frames continue without automatic fallback behavior")
	_expect(("decision timed out" if stall else "exited unexpectedly") in arena._python.last_error,
		"G: Correct diagnosis for process failure")
	_expect(pid != -1 and not OS.is_process_running(pid), "G: No live Python child after failure")
	print("G: %s; scene continued to tick %d" % [arena._python.last_error, arena._simulation.tick])
	arena.free()


func _step_after_reply(arena: Arena) -> bool:
	var tick_id := arena._simulation.tick + 1
	var replied := await _until(func() -> bool: return arena._python.has_reply(tick_id, Simulation.ROBOT_ID))
	_expect(replied, "Expected reply for tick %d: %s" % [tick_id, arena._python.last_error])
	if replied:
		arena._on_tick_timer_timeout()
	return replied


func _until(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 4000
	while not condition.call():
		if Time.get_ticks_msec() >= deadline:
			return false
		await process_frame
	return true


func _spawn(path: String, manual: bool = true, timeout_ms: int = 2000) -> Arena:
	var arena := ArenaScene.instantiate() as Arena
	arena.behavior_path = path
	arena.python_timeout_ms = timeout_ms
	(arena.get_node("TickTimer") as Timer).paused = manual
	root.add_child(arena)
	return arena


func _fixture(name: String, source: String) -> String:
	var path := "user://m15 %s-%d.py" % [name, OS.get_process_id()]
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "Fixture file can be written")
	if file != null:
		file.store_string(source.strip_edges() + "\n")
		file.close()
		_files.append(ProjectSettings.globalize_path(path))
	return path


func _at_spawn_without_ore(arena: Arena) -> bool:
	var sim := arena._simulation
	return (sim.worker.cell == Simulation.WORKER_START and sim.worker.carried_ore == 0
		and sim.stored_ore == [0, 0] and sim.ore_remaining == [18, 18])


func _snapshot(sim: Simulation) -> String:
	return JSON.stringify([sim.tick, sim.worker.cell.x, sim.worker.cell.y, sim.worker.carried_ore,
		sim.worker.mining_ticks, sim.stored_ore, sim.ore_remaining, sim.last_action])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)
