@tool
extends EditorPlugin
# res://addons/godot_bridge/plugin.gd
## Godot Bridge Version 2.8.0

const DOCK_SCRIPT_PATH = "res://addons/godot_bridge/dock.gd"
const REPORTER_PATH = "res://addons/godot_bridge/error_reporter.gd"
const AUTOLOAD_NAME = "GodotBridgeErrors"
const SETTINGS_PATH = "res://addons/godot_bridge/settings.cfg"
const MAX_BODY_BYTES = 5 * 1024 * 1024
const MAX_HEADER_BYTES = 64 * 1024
const CONNECTION_TIMEOUT_MSEC = 5000
const MAX_READ_CHARS = 60000
const MAX_LIST_ENTRIES = 5000
const LOOPBACK_ADDRESSES = ["127.0.0.1", "localhost"]

var tcp_server: TCPServer
var connections: Array = []

var bind_address: String = "127.0.0.1"
var port: int = 9090
var auth_token: String = ""
var cors_origin: String = ""
var auto_start: bool = false

var dock: Control
var is_running: bool = false
var _output_mark: int = 0
var _capture: ErrorCapture
var _debugger: BridgeDebugger

## Receives engine errors directly (Godot 4.5+ Logger API), so we don't
## depend on scraping the Output panel. GDScript parse errors raised by
## GDScript.reload() arrive here with file, line and message.
class ErrorCapture extends Logger:
	var mutex := Mutex.new()
	var entries: Array = []
	var active: bool = false

	func begin() -> void:
		mutex.lock()
		entries.clear()
		active = true
		mutex.unlock()

	func end() -> Array:
		mutex.lock()
		active = false
		var out := entries.duplicate()
		entries.clear()
		mutex.unlock()
		return out

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if not active:
			return
		mutex.lock()
		entries.append({
			"function": function,
			"file": file,
			"line": line,
			"code": code,
			"rationale": rationale,
			"error_type": error_type,
		})
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

## Receives errors forwarded by error_reporter.gd from the running game.
class BridgeDebugger extends EditorDebuggerPlugin:
	const MAX_ERRORS = 500
	var errors: Array = []

	func _has_capture(prefix: String) -> bool:
		return prefix == "godot_bridge"

	func _capture(message: String, data: Array, _session_id: int) -> bool:
		if message != "godot_bridge:error":
			return false
		if data.size() < 7:
			return true
		var text: String = str(data[3])
		if not str(data[4]).is_empty():
			text = str(data[4]) if text.is_empty() else text + " - " + str(data[4])
		if errors.size() >= MAX_ERRORS:
			errors.pop_front()
		errors.append({
			"function": str(data[0]),
			"file": str(data[1]),
			"line": int(data[2]),
			"message": text,
			"error_type": int(data[5]),
			"stack": str(data[6]),
		})
		return true

var command_enabled: Dictionary = {
	"ping": true,
	"get_commands": true,
	"get_scene_tree": true,
	"get_selected_nodes": true,
	"get_node_properties": true,
	"get_node_signals": true,
	"get_open_scenes": true,
	"read_file": true,
	"list_dir": true,
	"get_open_script": true,
	"get_output": true,
	"get_errors": true,
	"validate_script": true,
	"class_info": true,
	"write_file": true,
	"make_dir": true,
	"delete_file": false,
	"move_file": true,
	"copy_file": true,
	"delete_dir": true,
	"spawn_node": true,
	"spawn_packed_scene": true,
	"remove_node": true,
	"reparent_node": true,
	"rename_node": true,
	"set_node_property": true,
	"attach_script": true,
	"add_to_group": true,
	"connect_signal": true,
	"create_scene": true,
	"save_scene": true,
	"open_scene": true,
	"set_main_scene": true,
	"add_input_action": true,
	"run_project": true,
	"run_current_scene": true,
	"stop_project": true,
}

const COMMAND_DOCS = {
	"ping": "No payload. Returns project name and Godot version.",
	"get_commands": "No payload. Lists every command, whether it is enabled, and its payload.",
	"get_scene_tree": "Payload: {max_depth?: int}. Returns nodes with name, type, path, script.",
	"get_selected_nodes": "No payload. Returns selected nodes in the scene tree.",
	"get_node_properties": "Payload: {node_path: string, filter?: string}. Returns properties of a node.",
	"get_node_signals": "Payload: {node_path: string, connected_only?: bool}. Returns signals of a node.",
	"get_open_scenes": "No payload. Returns list of open scenes.",
	"read_file": "Payload: {path: string, offset?: int, limit?: int}. Returns file content.",
	"list_dir": "Payload: {path: string, recursive?: bool}. Returns directory listing.",
	"get_open_script": "No payload. Returns currently opened script.",
	"get_output": "Payload: {new_only?: bool}. Returns editor output.",
	"get_errors": "Payload: {limit?: int}. Returns {errors: editor Output-panel error lines, runtime_errors: errors from the running game, runtime_source: 'logger' or 'debugger_panel'}.",
	"validate_script": "Payload: {path: string}. Validates a script.",
	"class_info": "Payload: {class_name: string}. Returns class information.",
	"write_file": "Payload: {path: string, content: string}. Replaces file content.",
	"make_dir": "Payload: {path: string}. Creates directory.",
	"delete_file": "Payload: {path: string}. Deletes a file.",
	"move_file": "Payload: {source: string, target: string}. Moves a file from source to target.",
	"copy_file": "Payload: {source: string, target: string}. Copies a file from source to target.",
	"delete_dir": "Payload: {path: string}. Deletes a directory and all its contents.",
	"spawn_node": "Payload: {node_type: string, name?: string, parent?: string, properties?: object}. Spawns a node.",
	"spawn_packed_scene": "Payload: {scene_path: string, name?: string, parent?: string}. Instances a packed scene.",
	"remove_node": "Payload: {node_path: string}. Removes a node.",
	"reparent_node": "Payload: {node_path: string, new_parent: string}. Reparents a node.",
	"rename_node": "Payload: {node_path: string, new_name: string}. Renames a node.",
	"set_node_property": "Payload: {node_path: string, property: string, value: object}. Sets a node property.",
	"attach_script": "Payload: {node_path: string, script_path: string}. Attaches a script to a node.",
	"add_to_group": "Payload: {node_path: string, group: string}. Adds a node to a group.",
	"connect_signal": "Payload: {source: string, target: string, signal: string, method: string}. Connects a signal.",
	"create_scene": "Payload: {path: string}. Creates a new scene. Opening is deferred; poll get_open_scenes.",
	"save_scene": "No payload. Saves the current scene (deferred).",
	"open_scene": "Payload: {path: string}. Opens a scene (deferred).",
	"set_main_scene": "Payload: {path: string}. Sets the main scene.",
	"add_input_action": "Payload: {action: string, events: array, deadzone?: float}. Event objects: {type: 'key', key: 'W'}, {type: 'mouse_button', button: int}, {type: 'joypad_button', button: int}.",
	"run_project": "No payload. Runs the project (deferred). Clears collected runtime errors.",
	"run_current_scene": "No payload. Runs the current scene (deferred). Clears collected runtime errors.",
	"stop_project": "No payload. Stops the running project.",
}


func _enter_tree() -> void:
	_load_settings()
	_capture = ErrorCapture.new()
	OS.add_logger(_capture)

	# Runtime error forwarding. Kept before the dock load so a dock failure can't skip it.
	_debugger = BridgeDebugger.new()
	add_debugger_plugin(_debugger)
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, REPORTER_PATH)

	var dock_script = load(DOCK_SCRIPT_PATH)
	if dock_script == null:
		push_error("Godot Bridge: could not load %s." % DOCK_SCRIPT_PATH)
		return
	dock = dock_script.new()
	dock.name = "Godot Bridge"
	dock.set("bridge", self)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	if auto_start:
		start_server()
	dock.call("refresh")

func _exit_tree() -> void:
	stop_server()
	if _capture:
		OS.remove_logger(_capture)
		_capture = null
	if _debugger:
		remove_debugger_plugin(_debugger)
		_debugger = null
	if ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null

func _process(_delta: float) -> void:
	if not is_running:
		return
	_accept_new_connections()
	_service_connections()

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		bind_address = str(cfg.get_value("server", "bind_address", "127.0.0.1"))
		port = int(cfg.get_value("server", "port", 9090))
		auth_token = str(cfg.get_value("server", "auth_token", ""))
		cors_origin = str(cfg.get_value("server", "cors_origin", ""))
		auto_start = bool(cfg.get_value("server", "auto_start", false))
		for key in command_enabled.keys():
			command_enabled[key] = bool(cfg.get_value("commands", key, command_enabled[key]))
	else:
		generate_token()
		save_settings()

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("server", "bind_address", bind_address)
	cfg.set_value("server", "port", port)
	cfg.set_value("server", "auth_token", auth_token)
	cfg.set_value("server", "cors_origin", cors_origin)
	cfg.set_value("server", "auto_start", auto_start)
	for key in command_enabled.keys():
		cfg.set_value("commands", key, command_enabled[key])
	cfg.save(SETTINGS_PATH)

func generate_token() -> String:
	auth_token = Crypto.new().generate_random_bytes(24).hex_encode()
	return auth_token

func start_server() -> String:
	stop_server()
	if not LOOPBACK_ADDRESSES.has(bind_address) and auth_token.is_empty():
		return "Refusing to start: set a token when binding beyond localhost."
	tcp_server = TCPServer.new()
	var err := tcp_server.listen(port, bind_address)
	if err != OK:
		tcp_server = null
		is_running = false
		return "Failed to start (error code %d). Is port %d in use?" % [err, port]
	is_running = true
	return "Listening on %s:%d" % [bind_address, port]

func stop_server() -> void:
	for conn in connections:
		var peer: StreamPeerTCP = conn.get("peer")
		if peer and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()
	connections.clear()
	if tcp_server:
		if tcp_server.is_listening():
			tcp_server.stop()
		tcp_server = null
	is_running = false

func _accept_new_connections() -> void:
	if tcp_server == null or not tcp_server.is_listening():
		return
	while tcp_server.is_connection_available():
		var peer := tcp_server.take_connection()
		connections.append({
			"peer": peer,
			"buffer": PackedByteArray(),
			"headers_parsed": false,
			"header_text": "",
			"header_end_byte": -1,
			"content_length": 0,
			"start_time": Time.get_ticks_msec(),
		})

func _find_header_end(buf: PackedByteArray) -> int:
	var sz := buf.size()
	for i in range(sz - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i + 4
	return -1

func _service_connections() -> void:
	var i := connections.size() - 1
	while i >= 0:
		var conn: Dictionary = connections[i]
		var peer: StreamPeerTCP = conn["peer"]
		peer.poll()

		var status := peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			connections.remove_at(i)
			i -= 1
			continue

		if Time.get_ticks_msec() - int(conn["start_time"]) > CONNECTION_TIMEOUT_MSEC:
			_queue_response(conn, 408, "{\"ok\":false,\"error\":\"Request timeout\"}")
			connections.remove_at(i)
			i -= 1
			continue

		var avail := peer.get_available_bytes()
		if avail > 0:
			var chunk := peer.get_partial_data(avail)
			if chunk[0] == OK:
				conn["buffer"].append_array(chunk[1])

		if not conn["headers_parsed"]:
			var header_end_byte := _find_header_end(conn["buffer"])
			if header_end_byte == -1:
				if conn["buffer"].size() > MAX_HEADER_BYTES:
					_queue_response(conn, 400, "{\"ok\":false,\"error\":\"Headers too large\"}")
					connections.remove_at(i)
				i -= 1
				continue

			conn["headers_parsed"] = true
			conn["header_end_byte"] = header_end_byte
			var header_bytes: PackedByteArray = conn["buffer"].slice(0, header_end_byte - 4)
			var header_text := header_bytes.get_string_from_utf8()
			conn["header_text"] = header_text

			if header_text.begins_with("OPTIONS"):
				_queue_response(conn, 200, "{}")
				connections.remove_at(i)
				i -= 1
				continue

			var cl := 0
			for line in header_text.split("\r\n"):
				if line.to_lower().begins_with("content-length:"):
					cl = int(line.substr(line.find(":") + 1).strip_edges())

			if cl > MAX_BODY_BYTES:
				_queue_response(conn, 413, "{\"ok\":false,\"error\":\"Payload too large\"}")
				connections.remove_at(i)
				i -= 1
				continue

			conn["content_length"] = cl

		# Headers are parsed at this point; wait for the full body.
		var body_available: int = conn["buffer"].size() - int(conn["header_end_byte"])
		if body_available >= int(conn["content_length"]):
			var start: int = conn["header_end_byte"]
			var body_bytes: PackedByteArray = conn["buffer"].slice(start, start + int(conn["content_length"]))
			var body_text := body_bytes.get_string_from_utf8()
			# Remove first so a failing command can't leave a stale entry behind.
			connections.remove_at(i)
			_handle_request(conn, conn["header_text"], body_text)

		i -= 1

func _handle_request(conn: Dictionary, header_text: String, body_text: String) -> void:
	if not _check_auth(header_text):
		_queue_response(conn, 401, "{\"ok\":false,\"error\":\"Unauthorized\"}")
		return

	var json := JSON.new()
	if json.parse(body_text) != OK:
		_queue_response(conn, 400, "{\"ok\":false,\"error\":\"Invalid JSON payload\"}")
		return

	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		_queue_response(conn, 400, "{\"ok\":false,\"error\":\"Payload must be a JSON object\"}")
		return

	var command: String = str(data.get("command", ""))
	var payload = data.get("payload", {})

	if not command_enabled.get(command, false):
		_queue_response(conn, 403, _err("Command disabled or unknown: " + command))
		return

	var result: String = _execute_command(command, payload)
	_queue_response(conn, 200, result)

func _check_auth(header_text: String) -> bool:
	if auth_token.is_empty():
		return true
	for line in header_text.split("\r\n"):
		if line.to_lower().begins_with("authorization:"):
			var value := line.substr(line.find(":") + 1).strip_edges()
			if value == "Bearer " + auth_token:
				return true
	return false

func _resolve_safe_path(path: String) -> String:
	var candidate := path.strip_edges()
	if candidate.is_empty():
		return ""
	if not candidate.begins_with("res://"):
		candidate = "res://" + candidate.trim_prefix("/")
	candidate = candidate.simplify_path()
	if not candidate.begins_with("res://") or candidate.find("..") != -1:
		return ""
	return candidate

func _is_protected(path: String) -> bool:
	return path.begins_with("res://addons/godot_bridge") or path.begins_with("res://.godot")

func _is_write_protected(path: String) -> bool:
	return _is_protected(path) or path == "res://project.godot" or path == "res://"

func _err(message: String) -> String:
	return JSON.stringify({"ok": false, "error": message})

func _ok(extra: Dictionary = {}) -> String:
	var result: Dictionary = {"ok": true}
	result.merge(extra)
	return JSON.stringify(result)

func _execute_command(command: String, payload) -> String:
	if typeof(payload) != TYPE_DICTIONARY:
		payload = {}

	match command:
		"ping": return _cmd_ping()
		"get_commands": return _cmd_get_commands()
		"get_scene_tree": return _cmd_get_scene_tree(payload)
		"get_selected_nodes": return _cmd_get_selected_nodes()
		"get_node_properties": return _cmd_get_node_properties(payload)
		"get_node_signals": return _cmd_get_node_signals(payload)
		"get_open_scenes": return _ok({"scenes": Array(EditorInterface.get_open_scenes())})
		"read_file": return _cmd_read_file(payload)
		"list_dir": return _cmd_list_dir(payload)
		"get_open_script": return _cmd_get_open_script()
		"get_output": return _cmd_get_output(payload)
		"get_errors": return _cmd_get_errors(payload)
		"validate_script": return _cmd_validate_script(payload)
		"class_info": return _cmd_class_info(payload)
		"write_file": return _cmd_write_file(payload)
		"make_dir": return _cmd_make_dir(payload)
		"delete_file": return _cmd_delete_file(payload)
		"move_file": return _cmd_move_file(payload)
		"copy_file": return _cmd_copy_file(payload)
		"delete_dir": return _cmd_delete_dir(payload)
		"spawn_node": return _cmd_spawn_node(payload)
		"spawn_packed_scene": return _cmd_spawn_packed_scene(payload)
		"remove_node": return _cmd_remove_node(payload)
		"reparent_node": return _cmd_reparent_node(payload)
		"rename_node": return _cmd_rename_node(payload)
		"set_node_property": return _cmd_set_node_property(payload)
		"attach_script": return _cmd_attach_script(payload)
		"add_to_group": return _cmd_add_to_group(payload)
		"connect_signal": return _cmd_connect_signal(payload)
		"create_scene": return _cmd_create_scene(payload)
		"save_scene": return _cmd_save_scene()
		"open_scene": return _cmd_open_scene(payload)
		"set_main_scene": return _cmd_set_main_scene(payload)
		"add_input_action": return _cmd_add_input_action(payload)
		"run_project":
			if _debugger:
				_debugger.errors.clear()
			call_deferred("_do_play", false)
			return _ok({"message": "Play scheduled (main scene)."})
		"run_current_scene":
			if _debugger:
				_debugger.errors.clear()
			call_deferred("_do_play", true)
			return _ok({"message": "Play scheduled (current scene)."})
		"stop_project":
			EditorInterface.stop_playing_scene()
			return _ok({"message": "Stopped playing scene."})
		_:
			return _err("Unrecognized command: " + command)

# ---------------------------------------------------------------------------
# Deferred editor operations (run outside the _process / request handling)
# ---------------------------------------------------------------------------

func _do_save_scene() -> void:
	EditorInterface.save_scene()

func _do_play(current: bool) -> void:
	if current:
		EditorInterface.play_current_scene()
	else:
		EditorInterface.play_main_scene()

func _do_open_scene(path: String) -> void:
	if FileAccess.file_exists(path):
		EditorInterface.open_scene_from_path(path)
	else:
		push_error("Godot Bridge: scene not found when opening: %s" % path)

# ---------------------------------------------------------------------------
# Read-only commands
# ---------------------------------------------------------------------------

func _cmd_ping() -> String:
	return _ok({
		"message": "pong - Godot Bridge is running.",
		"project": ProjectSettings.get_setting("application/config/name", "Untitled"),
		"godot_version": Engine.get_version_info().get("string", ""),
	})

func _cmd_get_commands() -> String:
	var out := {}
	for key in command_enabled.keys():
		out[key] = {"enabled": command_enabled[key], "usage": COMMAND_DOCS.get(key, "")}
	return _ok({"commands": out})

func _cmd_get_scene_tree(p: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene open in editor.")
	var max_depth := int(p.get("max_depth", 8))
	return _ok({"tree": _describe_node(root, root, 0, max_depth)})

func _cmd_get_selected_nodes() -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene open.")
	var items := []
	for node in EditorInterface.get_selection().get_selected_nodes():
		items.append({"name": str(node.name), "type": node.get_class(), "path": _rel_path(node)})
	return _ok({"selected_nodes": items})

func _cmd_get_node_properties(p: Dictionary) -> String:
	var node := _find_target_node(p)
	if node == null:
		return _err("Target node not found.")
	var filter := str(p.get("filter", "")).to_lower()
	var props := []
	for prop in node.get_property_list():
		var usage: int = prop.get("usage", 0)
		if usage & PROPERTY_USAGE_EDITOR:
			var pname: String = prop["name"]
			if not filter.is_empty() and not pname.to_lower().contains(filter):
				continue
			props.append({
				"name": pname,
				"type": _type_name(prop["type"]),
				"value": _variant_to_json_safe(node.get(pname)),
			})
	return _ok({"node": str(node.name), "properties": props})

func _cmd_get_node_signals(p: Dictionary) -> String:
	var node := _find_target_node(p)
	if node == null:
		return _err("Target node not found.")
	var root := EditorInterface.get_edited_scene_root()
	var connected_only := bool(p.get("connected_only", false))
	var signals_list := []
	for sig in node.get_signal_list():
		var conns := []
		for conn in node.get_signal_connection_list(sig["name"]):
			var callable_obj = conn["callable"].get_object()
			var target_path := ""
			if callable_obj is Node:
				if root and root.is_ancestor_of(callable_obj):
					target_path = str(root.get_path_to(callable_obj))
				else:
					target_path = str(callable_obj.name)
			conns.append({"target": target_path, "method": str(conn["callable"].get_method())})
		if connected_only and conns.is_empty():
			continue
		signals_list.append({"name": sig["name"], "connections": conns})
	return _ok({"node": str(node.name), "signals": signals_list})

func _cmd_read_file(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or _is_protected(safe) or not FileAccess.file_exists(safe):
		return _err("File not found or protected.")
	var f := FileAccess.open(safe, FileAccess.READ)
	if f == null:
		return _err("Could not open file (error %d)." % FileAccess.get_open_error())
	var content := f.get_as_text()
	f.close()
	var total := content.length()
	var offset := maxi(0, int(p.get("offset", 0)))
	var limit := int(p.get("limit", MAX_READ_CHARS))
	var truncated := offset + limit < total
	content = content.substr(offset, limit)
	return _ok({"path": safe, "content": content, "total_chars": total, "truncated": truncated})

func _cmd_list_dir(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "res://")))
	if safe.is_empty() or DirAccess.open(safe) == null:
		return _err("Could not open directory.")
	var recursive := bool(p.get("recursive", false))
	var entries := []
	_collect_entries(safe, "", recursive, entries)
	var truncated := entries.size() >= MAX_LIST_ENTRIES
	return _ok({"path": safe, "entries": entries, "truncated": truncated})

func _collect_entries(dir_path: String, rel_prefix: String, recursive: bool, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if out.size() >= MAX_LIST_ENTRIES:
			break
		if not fname.begins_with("."):
			var is_dir := dir.current_is_dir()
			var rel := rel_prefix + fname
			out.append({"name": rel, "is_dir": is_dir})
			if is_dir and recursive:
				var child_path := dir_path.path_join(fname)
				if not _is_protected(child_path):
					_collect_entries(child_path, rel + "/", recursive, out)
		fname = dir.get_next()
	dir.list_dir_end()

func _cmd_get_open_script() -> String:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return _err("Script editor unavailable.")
	var current = script_editor.get_current_editor()
	if current == null:
		return _err("No script currently open.")
	var base_editor = current.get_base_editor()
	var text: String = base_editor.text if base_editor else ""
	var cur_script = script_editor.get_current_script()
	var script_path: String = cur_script.resource_path if cur_script else ""
	return _ok({"path": script_path, "content": text})

func _cmd_get_output(p: Dictionary) -> String:
	var label := _log_label()
	if label == null:
		return _err("Output panel not found.")
	var txt := label.get_parsed_text()
	var total := txt.length()
	if bool(p.get("new_only", false)):
		if _output_mark > total:
			_output_mark = 0
		txt = txt.substr(_output_mark)
	_output_mark = total
	return _ok({"output": txt.strip_edges()})

func _cmd_get_errors(p: Dictionary) -> String:
	var limit := maxi(1, int(p.get("limit", 100)))

	# 1. Editor-side errors (Output panel).
	var found := []
	var label := _log_label()
	if label:
		for line in label.get_parsed_text().split("\n"):
			var l := line.strip_edges()
			if l.begins_with("ERROR:") or l.begins_with("SCRIPT ERROR:") or l.begins_with("USER ERROR:") or l.begins_with("Parse Error:"):
				found.append(l)
		if found.size() > limit:
			found = found.slice(found.size() - limit)

	# 2. Runtime errors from the running game. Primary source: errors forwarded by
	#    the in-game Logger. Fallback: read the editor's Debugger > Errors tab.
	var runtime: Array = []
	var source := "none"
	if _debugger and not _debugger.errors.is_empty():
		runtime = _debugger.errors.duplicate()
		source = "logger"
	else:
		runtime = _read_debugger_errors()
		if not runtime.is_empty():
			source = "debugger_panel"
	if runtime.size() > limit:
		runtime = runtime.slice(runtime.size() - limit)

	if label == null and _debugger == null and runtime.is_empty():
		return _err("No error sources available.")

	return _ok({
		"errors": found,
		"runtime_errors": runtime,
		"runtime_source": source,
		"count": found.size() + runtime.size(),
	})

## Reads the Debugger > Errors tab. Relies on editor-internal node layout, so it is
## only used when the Logger pipeline has nothing.
func _read_debugger_errors() -> Array:
	var out: Array = []
	var debuggers: Array = []
	_collect_by_class(EditorInterface.get_base_control(), "ScriptEditorDebugger", debuggers)
	for dbg in debuggers:
		var errors_tab = dbg.find_child("Errors", true, false)
		if errors_tab == null:
			continue
		var trees: Array = []
		_collect_by_class(errors_tab, "Tree", trees)
		for tree in trees:
			var root: TreeItem = tree.get_root()
			if root == null:
				continue
			var item := root.get_first_child()
			while item:
				var details: Array = []
				var child := item.get_first_child()
				while child:
					details.append(_item_text(child, tree.columns))
					child = child.get_next()
				out.append({
					"message": _item_text(item, tree.columns),
					"details": details,
				})
				item = item.get_next()
	return out

func _collect_by_class(node: Node, cls: String, out: Array) -> void:
	if node == null:
		return
	if node.get_class() == cls:
		out.append(node)
	for c in node.get_children():
		_collect_by_class(c, cls, out)

func _item_text(item: TreeItem, columns: int) -> String:
	var parts: PackedStringArray = []
	for col in range(columns):
		var t := item.get_text(col).strip_edges()
		if not t.is_empty():
			parts.append(t)
	return " ".join(parts)

func _log_label() -> RichTextLabel:
	var log_node := _find_by_class(EditorInterface.get_base_control(), "EditorLog")
	if log_node == null:
		return null
	return _find_by_class(log_node, "RichTextLabel") as RichTextLabel

func _parse_check(path: String) -> Dictionary:
	var gs := GDScript.new()
	gs.source_code = FileAccess.get_file_as_string(path)

	var label := _log_label()
	var before := label.get_parsed_text().length() if label else 0

	if _capture:
		_capture.begin()
	var err := gs.reload()
	var captured: Array = _capture.end() if _capture else []

	if err == OK:
		return {"code": OK, "errors": [], "messages": []}

	var errors: Array = []
	var messages: Array = []
	for e in captured:
		var text: String = str(e["code"])
		if not str(e["rationale"]).is_empty():
			text = str(e["rationale"]) if text.is_empty() else text + " - " + str(e["rationale"])
		errors.append({"line": e["line"], "message": text, "reported_file": e["file"]})
		messages.append("%s:%d: %s" % [path, e["line"], text])

	if messages.is_empty() and label:
		var txt := label.get_parsed_text()
		var fresh := txt.substr(before) if txt.length() >= before else txt
		for line in fresh.split("\n"):
			var l := line.strip_edges()
			if not l.is_empty():
				messages.append(l)

	return {"code": err, "errors": errors, "messages": messages}

func _cmd_validate_script(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or not FileAccess.file_exists(safe):
		return _err("File not found.")
	if not safe.ends_with(".gd"):
		return _err("validate_script only supports .gd files.")
	var r: Dictionary = _parse_check(safe)
	if r["code"] == OK:
		return _ok({"valid": true, "path": safe})
	return JSON.stringify({
		"ok": false,
		"valid": false,
		"path": safe,
		"code": r["code"],
		"error": "Script failed to parse.",
		"errors": r["errors"],
		"messages": r["messages"],
	})

func _cmd_class_info(p: Dictionary) -> String:
	# Documented key is "class_name"; "class" is still accepted for compatibility.
	var cname := str(p.get("class_name", p.get("class", "")))
	if not ClassDB.class_exists(cname):
		return _err("Unknown class: " + cname)
	var methods := []
	for m in ClassDB.class_get_method_list(cname, true):
		methods.append(m["name"])
	return _ok({"class": cname, "methods": methods})

# ---------------------------------------------------------------------------
# File commands
# ---------------------------------------------------------------------------

func _cmd_write_file(p: Dictionary) -> String:
	if not p.has("content"):
		return _err("content is required.")
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or _is_write_protected(safe):
		return _err("Invalid or protected path.")
	DirAccess.make_dir_recursive_absolute(safe.get_base_dir())
	var f := FileAccess.open(safe, FileAccess.WRITE)
	if f == null:
		return _err("Could not open file for writing (error %d)." % FileAccess.get_open_error())
	f.store_string(str(p["content"]))
	f.close()
	EditorInterface.get_resource_filesystem().scan()
	return _ok({"path": safe})

func _cmd_make_dir(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or _is_write_protected(safe):
		return _err("Invalid or protected path.")
	DirAccess.make_dir_recursive_absolute(safe)
	EditorInterface.get_resource_filesystem().scan()
	return _ok({"path": safe})

func _cmd_delete_file(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or _is_write_protected(safe):
		return _err("Invalid or protected path.")
	if not FileAccess.file_exists(safe):
		return _err("File does not exist.")
	if DirAccess.remove_absolute(safe) != OK:
		return _err("Failed to delete file.")
	EditorInterface.get_resource_filesystem().scan()
	return _ok({"message": "Deleted " + safe})

func _cmd_move_file(p: Dictionary) -> String:
	var source_path := _resolve_safe_path(str(p.get("source", "")))
	var target_path := _resolve_safe_path(str(p.get("target", "")))

	if source_path.is_empty() or target_path.is_empty() or _is_write_protected(source_path) or _is_write_protected(target_path):
		return _err("Invalid or protected path.")

	if not FileAccess.file_exists(source_path):
		return _err("Source file does not exist.")

	var target_dir := target_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(target_dir):
		DirAccess.make_dir_recursive_absolute(target_dir)

	if DirAccess.copy_absolute(source_path, target_path) != OK:
		return _err("Failed to copy file.")

	var del_res := _cmd_delete_file({"path": source_path})
	var json := JSON.new()
	if json.parse(del_res) == OK and typeof(json.get_data()) == TYPE_DICTIONARY:
		if not json.get_data().get("ok", false):
			return del_res

	return _ok({"message": "Moved file from %s to %s" % [source_path, target_path]})

func _cmd_copy_file(p: Dictionary) -> String:
	var source_path := _resolve_safe_path(str(p.get("source", "")))
	var target_path := _resolve_safe_path(str(p.get("target", "")))

	if source_path.is_empty() or target_path.is_empty() or _is_write_protected(source_path) or _is_write_protected(target_path):
		return _err("Invalid or protected path.")

	if not FileAccess.file_exists(source_path):
		return _err("Source file does not exist.")

	var target_dir := target_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(target_dir):
		DirAccess.make_dir_recursive_absolute(target_dir)

	# copy_absolute is byte-exact, so binary files survive (get_as_text would not).
	if DirAccess.copy_absolute(source_path, target_path) != OK:
		return _err("Failed to copy file.")

	EditorInterface.get_resource_filesystem().scan()
	return _ok({"message": "Copied file from %s to %s" % [source_path, target_path]})

func _cmd_delete_dir(p: Dictionary) -> String:
	var path := _resolve_safe_path(str(p.get("path", "")))

	if path.is_empty() or _is_write_protected(path):
		return _err("Invalid or protected path.")

	var dir := DirAccess.open(path)
	if dir == null:
		return _err("Path is not a directory or does not exist.")

	dir.list_dir_begin()
	var fname := dir.get_next()
	var has_files := false
	while fname != "":
		if fname != "." and fname != "..":
			has_files = true
			break
		fname = dir.get_next()
	dir.list_dir_end()

	# Deleting contents requires the delete_file command to be enabled.
	if has_files and not command_enabled.get("delete_file", false):
		return _err("Delete file command is disabled.")

	var result := _delete_directory_contents(path)
	if result != OK:
		return _err("Failed to delete directory contents.")

	if DirAccess.remove_absolute(path) != OK:
		return _err("Failed to delete directory.")

	EditorInterface.get_resource_filesystem().scan()
	return _ok({"message": "Deleted directory %s" % path, "had_files": has_files})

func _delete_directory_contents(path: String) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return FAILED

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path := path.path_join(file_name)
			if dir.current_is_dir():
				var res := _delete_directory_contents(full_path)
				if res != OK:
					dir.list_dir_end()
					return res
				if DirAccess.remove_absolute(full_path) != OK:
					dir.list_dir_end()
					return FAILED
			else:
				if DirAccess.remove_absolute(full_path) != OK:
					dir.list_dir_end()
					return FAILED
		file_name = dir.get_next()
	dir.list_dir_end()
	return OK

# ---------------------------------------------------------------------------
# Node / scene commands
# ---------------------------------------------------------------------------

func _cmd_spawn_node(p: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene open.")
	var node_type := str(p.get("node_type", "Node"))
	if not ClassDB.class_exists(node_type) or not ClassDB.can_instantiate(node_type) or not ClassDB.is_parent_class(node_type, "Node"):
		return _err("Invalid or non-instantiable node type: " + node_type)
	var parent_node := _resolve_parent(p)
	if parent_node == null:
		return _err("Parent node not found.")
	var new_node := ClassDB.instantiate(node_type) as Node
	if new_node == null:
		return _err("Failed to instantiate: " + node_type)
	new_node.name = str(p.get("name", node_type))
	parent_node.add_child(new_node, true)
	new_node.owner = root

	var props = p.get("properties", {})
	if typeof(props) == TYPE_DICTIONARY:
		for key in props.keys():
			if str(key) in new_node:
				new_node.set(str(key), props[key])

	EditorInterface.mark_scene_as_unsaved()
	return _ok({"node_path": _rel_path(new_node)})

func _cmd_spawn_packed_scene(p: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene open.")
	var safe := _resolve_safe_path(str(p.get("scene_path", "")))
	if safe.is_empty() or not ResourceLoader.exists(safe):
		return _err("Scene not found.")
	var packed := load(safe) as PackedScene
	if packed == null:
		return _err("Failed to load scene as PackedScene.")
	var parent_node := _resolve_parent(p)
	if parent_node == null:
		return _err("Parent node not found.")
	var instance := packed.instantiate()
	if instance == null:
		return _err("Failed to instantiate scene.")
	if p.has("name"):
		instance.name = str(p["name"])
	parent_node.add_child(instance, true)
	instance.owner = root
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"node_path": _rel_path(instance)})

func _cmd_remove_node(p: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Node not found.")
	if node == root:
		return _err("Cannot remove the scene root.")
	var parent := node.get_parent()
	if parent:
		# Detach immediately so follow-up commands don't see the node; free afterwards.
		parent.remove_child(node)
	node.queue_free()
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"message": "Removed node"})

func _cmd_reparent_node(p: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err("No scene open.")
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Node not found.")
	if node == root:
		return _err("Cannot reparent the scene root.")
	var new_parent := _find_target_node(p.get("new_parent", ""), false)
	if new_parent == null:
		return _err("New parent not found.")
	if new_parent == node or node.is_ancestor_of(new_parent):
		return _err("Cannot reparent a node under itself or its descendants.")
	if new_parent == node.get_parent():
		return _ok({"node_path": _rel_path(node), "message": "Already a child of that parent."})

	# reparent() clears ownership, so remember which nodes belonged to the scene root.
	var owned: Array = []
	if node.owner == root:
		owned.append(node)
	for d in node.find_children("*", "", true, false):
		if d.owner == root:
			owned.append(d)

	node.reparent(new_parent, true)

	for n in owned:
		if is_instance_valid(n):
			n.owner = root

	EditorInterface.mark_scene_as_unsaved()
	return _ok({"node_path": _rel_path(node)})

func _cmd_rename_node(p: Dictionary) -> String:
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Node not found.")
	var new_name := str(p.get("new_name", "")).strip_edges()
	if new_name.is_empty():
		return _err("new_name is required.")
	node.name = new_name
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"node_path": _rel_path(node)})

func _cmd_set_node_property(p: Dictionary) -> String:
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Node not found.")
	var prop := str(p.get("property", ""))
	if prop.is_empty() or not (prop in node):
		return _err("Unknown property: " + prop)
	if not p.has("value"):
		return _err("value is required.")
	node.set(prop, p["value"])
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"message": "Property updated"})

func _cmd_attach_script(p: Dictionary) -> String:
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Node not found.")
	var safe := _resolve_safe_path(str(p.get("script_path", "")))
	if safe.is_empty() or not ResourceLoader.exists(safe):
		return _err("Script not found.")
	var scr := load(safe) as Script
	if scr == null:
		return _err("Failed to load script (does it have parse errors?).")
	node.set_script(scr)
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"message": "Script attached"})

func _cmd_add_to_group(p: Dictionary) -> String:
	var node := _find_target_node(p, false)
	if node == null:
		return _err("Node not found.")
	var group := str(p.get("group", "")).strip_edges()
	if group.is_empty():
		return _err("group is required.")
	node.add_to_group(group, true)
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"message": "Added to group"})

func _cmd_connect_signal(p: Dictionary) -> String:
	var source := _find_target_node(p.get("source", ""), false)
	var target := _find_target_node(p.get("target", ""), false)
	if source == null or target == null:
		return _err("Source or target node not found.")
	var sig := str(p.get("signal", ""))
	var method := str(p.get("method", ""))
	if not source.has_signal(sig):
		return _err("Source has no signal: " + sig)
	if method.is_empty():
		return _err("method is required.")
	var callable := Callable(target, method)
	if source.is_connected(sig, callable):
		return _ok({"message": "Signal already connected"})
	var err := source.connect(sig, callable, CONNECT_PERSIST)
	if err != OK:
		return _err("Failed to connect signal (error %d)." % err)
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"message": "Signal connected"})

func _cmd_create_scene(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or _is_write_protected(safe):
		return _err("Invalid or protected path.")
	if not safe.ends_with(".tscn") and not safe.ends_with(".scn"):
		safe += ".tscn"
	DirAccess.make_dir_recursive_absolute(safe.get_base_dir())
	var new_root := Node2D.new()
	new_root.name = safe.get_file().get_basename().to_pascal_case()
	var packed := PackedScene.new()
	var pack_err := packed.pack(new_root)
	new_root.free()
	if pack_err != OK:
		return _err("Failed to pack scene (error %d)." % pack_err)
	var save_err := ResourceSaver.save(packed, safe)
	if save_err != OK:
		return _err("Failed to save scene (error %d)." % save_err)
	EditorInterface.get_resource_filesystem().scan()
	call_deferred("_do_open_scene", safe)
	return _ok({"path": safe, "message": "Scene created; opening is scheduled."})

func _cmd_save_scene() -> String:
	call_deferred("_do_save_scene")
	return _ok({"message": "Save scheduled"})

func _cmd_open_scene(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or not FileAccess.file_exists(safe):
		return _err("Scene not found.")
	call_deferred("_do_open_scene", safe)
	return _ok({"message": "Open scheduled"})

func _cmd_set_main_scene(p: Dictionary) -> String:
	var safe := _resolve_safe_path(str(p.get("path", "")))
	if safe.is_empty() or not FileAccess.file_exists(safe):
		return _err("Scene not found.")
	ProjectSettings.set_setting("application/run/main_scene", safe)
	ProjectSettings.save()
	return _ok({"message": "Main scene updated"})

func _cmd_add_input_action(p: Dictionary) -> String:
	var action := str(p.get("action", "")).strip_edges()
	if action.is_empty():
		return _err("action is required.")
	var raw_events = p.get("events", [])
	if typeof(raw_events) != TYPE_ARRAY:
		return _err("events must be an array.")

	var events: Array = []
	for e in raw_events:
		if typeof(e) != TYPE_DICTIONARY:
			return _err("Each event must be an object.")
		var ev := _build_input_event(e)
		if ev == null:
			return _err("Unsupported or invalid event: " + JSON.stringify(e))
		events.append(ev)

	var deadzone := float(p.get("deadzone", 0.5))
	ProjectSettings.set_setting("input/" + action, {"deadzone": deadzone, "events": events})
	ProjectSettings.save()

	if InputMap.has_action(action):
		InputMap.erase_action(action)
	InputMap.add_action(action, deadzone)
	for ev in events:
		InputMap.action_add_event(action, ev)
	return _ok({"message": "Action added", "action": action, "event_count": events.size()})

func _build_input_event(e: Dictionary) -> InputEvent:
	match str(e.get("type", "key")):
		"key":
			var keycode := OS.find_keycode_from_string(str(e.get("key", "")))
			if keycode == KEY_NONE:
				return null
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			ev.ctrl_pressed = bool(e.get("ctrl", false))
			ev.shift_pressed = bool(e.get("shift", false))
			ev.alt_pressed = bool(e.get("alt", false))
			ev.meta_pressed = bool(e.get("meta", false))
			return ev
		"mouse_button":
			var ev := InputEventMouseButton.new()
			ev.button_index = int(e.get("button", 1))
			return ev
		"joypad_button":
			var ev := InputEventJoypadButton.new()
			ev.button_index = int(e.get("button", 0))
			return ev
	return null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _find_target_node(target_info, _allow_fallback: bool = true) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	var path_str := ""
	if target_info is String or target_info is NodePath:
		path_str = str(target_info)
	elif target_info is Dictionary:
		path_str = str(target_info.get("node_path", target_info.get("path", "")))
	if path_str.is_empty():
		return null
	if path_str == "." or path_str == str(root.name):
		return root
	return root.get_node_or_null(NodePath(path_str))

func _resolve_parent(p: Dictionary) -> Node:
	if p.has("parent") and not str(p["parent"]).is_empty():
		return _find_target_node(p["parent"], false)
	return EditorInterface.get_edited_scene_root()

func _rel_path(node: Node) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return ""
	return str(root.get_path_to(node))

func _type_name(id: int) -> String:
	return type_string(id)

func _variant_to_json_safe(v: Variant) -> Variant:
	if v is Object or v is Callable or v is Signal or v is RID:
		return str(v)
	return v

func _describe_node(node: Node, root: Node, depth: int, max_depth: int) -> Dictionary:
	var children_arr := []
	if depth < max_depth:
		for child in node.get_children():
			children_arr.append(_describe_node(child, root, depth + 1, max_depth))
	var script_path := ""
	var scr = node.get_script()
	if scr:
		script_path = scr.resource_path
	return {
		"name": str(node.name),
		"type": node.get_class(),
		"path": str(root.get_path_to(node)),
		"script": script_path,
		"children": children_arr
	}

func _find_by_class(node: Node, cls: String) -> Node:
	if node == null:
		return null
	if node.get_class() == cls:
		return node
	for c in node.get_children():
		var r := _find_by_class(c, cls)
		if r != null:
			return r
	return null

func _queue_response(conn: Dictionary, status_code: int, response_body: String) -> void:
	var peer: StreamPeerTCP = conn["peer"]
	var reason := _http_reason(status_code)
	var body_bytes := response_body.to_utf8_buffer()

	var response := "HTTP/1.1 %d %s\r\n" % [status_code, reason]
	response += "Content-Type: application/json; charset=utf-8\r\n"
	response += "Content-Length: %d\r\n" % body_bytes.size()
	if not cors_origin.is_empty():
		response += "Access-Control-Allow-Origin: %s\r\n" % cors_origin
		response += "Access-Control-Allow-Headers: Authorization, Content-Type\r\n"
		response += "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
	response += "Connection: close\r\n\r\n"

	var full_bytes := response.to_utf8_buffer()
	full_bytes.append_array(body_bytes)

	if peer and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data(full_bytes)
		peer.disconnect_from_host()

func _http_reason(code: int) -> String:
	match code:
		200: return "OK"
		400: return "Bad Request"
		401: return "Unauthorized"
		403: return "Forbidden"
		404: return "Not Found"
		408: return "Request Timeout"
		413: return "Payload Too Large"
		_: return "Error"
