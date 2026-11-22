extends Node3D

const Simulation = preload("res://simulation/arena_simulation.gd")
const Worker = preload("res://simulation/worker.gd")
const PythonBridge = preload("res://python_bridge/python_bridge.gd")
const WorkerProtocol = preload("res://python_bridge/worker_protocol.gd")

const TILE_COLORS := [Color("32474f"), Color("3d535b")]
const TEAM_COLORS := [Color("369fdf"), Color("d77965")]
const RUNNER_PATH := "res://python/runner.py"

@export var behavior_path: String = "res://python/worker.py"
@export_range(100, 10000, 100) var python_timeout_ms: int = 2000

@onready var _board: Node3D = $Board
@onready var _worker_mesh: MeshInstance3D = $Worker
@onready var _tick_label: Label = %TickLabel
@onready var _ore_label: Label = %OreLabel
@onready var _inventory_label: Label = %InventoryLabel
@onready var _action_label: Label = %ActionLabel
@onready var _python_status: Label = %PythonStatus
@onready var _python_file: Label = %PythonFile
@onready var _python_error: Label = %PythonError
@onready var _tick_timer: Timer = $TickTimer

var _simulation := Simulation.new()
var _python := PythonBridge.new()
var _ore_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	_build_board()
	_python.start(RUNNER_PATH, behavior_path, python_timeout_ms)
	_python_file.text = "Behavior  %s" % behavior_path.get_file()
	_refresh_view()
	_refresh_python_status()


func _process(_delta: float) -> void:
	_python.poll()
	_request_next_decision()
	if _tick_timer.is_stopped() and _python.status != PythonBridge.STARTING:
		_tick_timer.start()
	_refresh_python_status()


func _exit_tree() -> void:
	_python.close()


func _on_tick_timer_timeout() -> void:
	_python.poll()
	var tick_id := _simulation.tick + 1
	var reply := _python.take_reply(tick_id, Simulation.ROBOT_ID)
	var action := {"kind": Worker.Action.WAIT}
	if reply.get("type", "") == "decision":
		action = WorkerProtocol.action_request(reply.action)
	_simulation.step_with_action(action)
	if _simulation.last_action == "Rejected":
		_python.report_rejected_action(tick_id)
	_request_next_decision()
	_refresh_view()
	_refresh_python_status()


func _request_next_decision() -> void:
	if _python.can_request():
		_python.request_decision(_simulation.tick + 1, Simulation.ROBOT_ID,
			WorkerProtocol.observation(_simulation.observe_worker()))


func _refresh_python_status() -> void:
	_python_status.text = "Python  %s" % _python.status
	_python_error.visible = not _python.last_error.is_empty()
	_python_error.text = "Last error  %s" % _python.last_error.replace("\n", " ")


func _build_board() -> void:
	var tile := BoxMesh.new()
	tile.size = Vector3(0.96, 0.16, 0.96)
	var tile_materials := [_material(TILE_COLORS[0]), _material(TILE_COLORS[1])]
	for z in range(Simulation.SIZE.y):
		for x in range(Simulation.SIZE.x):
			_add_mesh(tile, tile_materials[(x + z) % 2], _grid_position(Vector2i(x, z), -0.08))

	var wall := BoxMesh.new()
	wall.size = Vector3(0.76, 0.85, Simulation.SIZE.y - 0.04)
	var wall_cell := Vector2i(Simulation.WALL_COLUMN, floori(Simulation.SIZE.y / 2.0))
	_add_mesh(wall, _material(Color("9996a3")), _grid_position(wall_cell, wall.size.y / 2.0))

	var hq := BoxMesh.new()
	hq.size = Vector3(0.88, 1.1, 0.88)
	var ore := CylinderMesh.new()
	ore.top_radius = 0.22
	ore.bottom_radius = 0.36
	ore.height = 0.64
	ore.radial_segments = 6
	var ore_material := _material(Color("efbc52"))
	for team in range(Simulation.HQ_CELLS.size()):
		_add_mesh(hq, _material(TEAM_COLORS[team]), _grid_position(Simulation.HQ_CELLS[team], 0.55))
		_ore_meshes.append(_add_mesh(ore, ore_material, _grid_position(Simulation.ORE_CELLS[team], 0.32)))


func _refresh_view() -> void:
	var worker := _simulation.worker
	_worker_mesh.position = _grid_position(worker.cell, 0.23)
	for team in range(_ore_meshes.size()):
		_ore_meshes[team].visible = _simulation.ore_remaining[team] > 0
	_tick_label.text = "Tick  %d" % _simulation.tick
	_ore_label.text = "HQ Ore  %d" % _simulation.stored_ore[Simulation.PLAYER]
	_inventory_label.text = "Worker Ore  %d / %d" % [worker.carried_ore, Worker.CAPACITY]
	var action := _simulation.last_action
	if worker.mining_ticks > 0:
		action += "  (%d / %d)" % [worker.mining_ticks, Worker.TICKS_PER_ORE]
	_action_label.text = "Worker action  %s" % action


func _grid_position(cell: Vector2i, height: float) -> Vector3:
	var center := Vector2(Simulation.SIZE - Vector2i.ONE) / 2.0
	return Vector3(cell.x - center.x, height, cell.y - center.y)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	return material


func _add_mesh(mesh: Mesh, material: Material, location: Vector3) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = location
	_board.add_child(instance)
	return instance
