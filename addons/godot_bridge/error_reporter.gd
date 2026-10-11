extends Node
# Godot Bridge Version 2.8.0
# res://addons/godot_bridge/error_reporter.gd
## Runs inside the game process. Forwards engine/script errors to the editor
## over the debugger connection so the bridge's get_errors command can return them.

class GameLogger extends Logger:
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		if not EngineDebugger.is_active():
			return
		var trace := ""
		for b in script_backtraces:
			trace += b.format() + "\n"
		EngineDebugger.send_message("godot_bridge:error", [function, file, line, code, rationale, error_type, trace.strip_edges()])

	func _log_message(_message: String, _error: bool) -> void:
		pass

var _logger := GameLogger.new()

func _init() -> void:
	OS.add_logger(_logger)
