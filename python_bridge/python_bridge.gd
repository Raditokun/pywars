extends RefCounted

const STARTING := "Starting"
const CONNECTED := "Connected"
const OFFLINE := "Offline"
const READ_BYTES: int = 4096
const MAX_LINE_BYTES: int = 16384
const MAX_REQUEST_BYTES: int = 2048

var status: String = OFFLINE
var last_error: String = ""

var _pid: int = -1
var _stdio: FileAccess
var _stderr: FileAccess
var _stdout_buffer := PackedByteArray()
var _stderr_buffer := PackedByteArray()
var _timeout_ms: int
var _deadline_ms: int = 0
var _pending_tick: int = -1
var _pending_robot: String = ""
var _missed_boundary: bool = false
var _reply: Dictionary = {}


func start(runner_path: String, behavior_path: String, timeout_ms: int) -> void:
	close()
	last_error = ""
	_timeout_ms = timeout_ms
	var executable := _find_python()
	if executable.is_empty():
		_report("Python executable not found. Set PYWARS_PYTHON to its absolute path or add Python to PATH.")
		return

	var runner_file := ProjectSettings.globalize_path(runner_path)
	var behavior_file := ProjectSettings.globalize_path(behavior_path)
	if not FileAccess.file_exists(runner_file) or not FileAccess.file_exists(behavior_file):
		_report("Could not find Python runner or behavior: %s, %s" % [runner_file, behavior_file])
		return

	var pipes := OS.execute_with_pipe(executable, ["-u", "-B", runner_file, behavior_file], false)
	if pipes.is_empty():
		_report("Could not start Python: %s" % executable)
		return

	_pid = pipes.pid
	_stdio = pipes.stdio
	_stderr = pipes.stderr
	status = STARTING
	_deadline_ms = Time.get_ticks_msec() + _timeout_ms


func can_request() -> bool:
	return status == CONNECTED and _pending_tick == -1



func request_decision(tick_id: int, robot_id: String, observation: Dictionary) -> void:
	if not can_request():
		return
	var request := {
		"type": "observe", "tick_id": tick_id, "robot_id": robot_id, "observation": observation,
	}
	var bytes := (JSON.stringify(request) + "\n").to_utf8_buffer()
	if bytes.size() > MAX_REQUEST_BYTES or not _stdio.store_buffer(bytes):
		_fail("Could not send the decision request for tick %d." % tick_id)
		return
	_pending_tick = tick_id
	_pending_robot = robot_id
	_deadline_ms = Time.get_ticks_msec() + _timeout_ms


func has_reply(tick_id: int, robot_id: String) -> bool:
	return tick_id == _pending_tick and robot_id == _pending_robot and not _reply.is_empty()


func take_reply(tick_id: int, robot_id: String) -> Dictionary:
	if has_reply(tick_id, robot_id):
		var reply := _reply
		_clear_request()
		return reply
	if tick_id == _pending_tick and robot_id == _pending_robot and not _missed_boundary:
		_missed_boundary = true
		_report("Tick %d decision missed its boundary. The worker idled." % tick_id)
	return {}


func poll() -> void:
	if _pid == -1:
		return

	_read_stderr()
	_stdout_buffer.append_array(_stdio.get_buffer(READ_BYTES))
	var newline := _stdout_buffer.find(10)
	while newline != -1:
		if newline > MAX_LINE_BYTES:
			_fail("Python protocol line exceeded the size limit.")
			return
		var line := _stdout_buffer.slice(0, newline).get_string_from_utf8()
		_stdout_buffer = _stdout_buffer.slice(newline + 1)
		_receive(line)
		if _pid == -1:
			return
		newline = _stdout_buffer.find(10)
	if _stdout_buffer.size() > MAX_LINE_BYTES:
		_fail("Unterminated Python protocol line exceeded the size limit.")
	elif not OS.is_process_running(_pid):
		_fail("Python runner exited unexpectedly.")
	elif _deadline_ms != 0 and Time.get_ticks_msec() >= _deadline_ms:
		if status == STARTING:
			_fail("Python startup timed out after %d ms." % _timeout_ms)
		else:
			_fail("Python decision timed out at tick %d after %d ms." % [_pending_tick, _timeout_ms])


func report_rejected_action(tick_id: int) -> void:
	_report("Tick %d: Godot rejected the Python action or target." % tick_id)


func close() -> void:
	if _pid != -1 and OS.is_process_running(_pid):
		var result := OS.kill(_pid)
		if result != OK:
			printerr("[Python bridge] Could not terminate runner: %s" % error_string(result))
	_pid = -1
	_stdio = null
	_stderr = null
	_stdout_buffer.clear()
	_stderr_buffer.clear()
	status = OFFLINE
	_clear_request()


func _receive(line: String) -> void:
	var parser := JSON.new()
	if parser.parse(line) != OK or not parser.data is Dictionary:
		_report("Ignored malformed Python protocol message.")
		return
	var message: Dictionary = parser.data

	var message_type: Variant = message.get("type")
	if status == STARTING:
		if message_type is String and message_type == "ready":
			status = CONNECTED
			_deadline_ms = 0
			return
		if message_type is String and message_type == "startup_error" and message.get("message") is String:
			_fail("Python startup error: %s" % message.message)
			return

	if not message_type is String or message_type not in ["decision", "error"]:
		_report("Ignored unexpected Python message type.")
		return
	var tick_id: Variant = message.get("tick_id")
	var robot_id: Variant = message.get("robot_id")
	if (_pending_tick == -1 or not (tick_id is int or tick_id is float) or tick_id != _pending_tick
		or not robot_id is String or robot_id != _pending_robot):
		_report("Ignored Python reply with a stale or mismatched tick/robot ID.")
		return
	if not _reply.is_empty():
		_report("Ignored duplicate Python reply for tick %d." % _pending_tick)
		return
	if message_type == "decision" and not message.has("action"):
		_report("Ignored Python decision without an action.")
		return
	if message_type == "error" and not message.get("message") is String:
		_report("Ignored Python error without a message.")
		return
	if _missed_boundary:
		_report("Ignored late Python reply for tick %d." % _pending_tick)
		_clear_request()
		return

	if message_type == "error":
		_report("Python error at tick %d: %s" % [_pending_tick, message.message])
	_reply = message
	_deadline_ms = 0


func _read_stderr() -> void:
	_stderr_buffer.append_array(_stderr.get_buffer(READ_BYTES))
	var newline := _stderr_buffer.find(10)
	while newline != -1:
		printerr("[Python stderr] %s" % _stderr_buffer.slice(0, newline).get_string_from_utf8().trim_suffix("\r"))
		_stderr_buffer = _stderr_buffer.slice(newline + 1)
		newline = _stderr_buffer.find(10)
	if _stderr_buffer.size() > MAX_LINE_BYTES:
		printerr("[Python stderr] Discarded an oversized diagnostic line.")
		_stderr_buffer.clear()


func _clear_request() -> void:
	_pending_tick = -1
	_pending_robot = ""
	_missed_boundary = false
	_deadline_ms = 0
	_reply = {}


func _fail(message: String) -> void:
	_report(message)
	close()


func _report(message: String) -> void:
	last_error = message
	printerr("[Python bridge] %s" % message)


static func _find_python() -> String:
	var configured := OS.get_environment("PYWARS_PYTHON").strip_edges().replace("\\", "/")
	if not configured.is_empty():
		return configured if configured.is_absolute_path() and FileAccess.file_exists(configured) else ""

	var windows := OS.get_name() == "Windows"
	var executable := "python.exe" if windows else "python3"
	for entry in OS.get_environment("PATH").split(";" if windows else ":", false):
		var directory := entry.strip_edges().trim_prefix('"').trim_suffix('"').replace("\\", "/")
		if not directory.is_absolute_path() or (windows and directory.to_lower().contains("/microsoft/windowsapps")):
			continue
		var candidate := directory.path_join(executable)
		if FileAccess.file_exists(candidate):
			return candidate
	return ""
