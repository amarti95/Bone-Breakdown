@tool
extends Resource
class_name FmvClip

func _editor_emit_changed_if_needed() -> void:
	if Engine.is_editor_hint():
		emit_changed()


func _on_nested_qte_window_changed() -> void:
	_editor_emit_changed_if_needed()


func _disconnect_qte_signals(wins: Array) -> void:
	for w_any in wins:
		var w := w_any as Resource
		if w != null and w.changed.is_connected(_on_nested_qte_window_changed):
			w.changed.disconnect(_on_nested_qte_window_changed)


func _connect_qte_signals(wins: Array) -> void:
	for w_any in wins:
		var w := w_any as Resource
		if w != null and not w.changed.is_connected(_on_nested_qte_window_changed):
			w.changed.connect(_on_nested_qte_window_changed)


func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_POSTINITIALIZE:
		call_deferred("_editor_sync_qte_window_signals")


func _editor_sync_qte_window_signals() -> void:
	if not Engine.is_editor_hint():
		return
	_disconnect_qte_signals(_windows)
	_connect_qte_signals(_windows)


@export var id: String = "":
	set(v):
		if id == v:
			return
		id = v
		_editor_emit_changed_if_needed()

@export var video: VideoStream:
	set(v):
		if video == v:
			return
		video = v
		_editor_emit_changed_if_needed()

@export var on_finish_next_clip_id: String = "":
	set(v):
		if on_finish_next_clip_id == v:
			return
		on_finish_next_clip_id = v
		_editor_emit_changed_if_needed()

var _windows: Array[FmvQteWindow] = []

@export var windows: Array[FmvQteWindow] = []:
	set(next):
		var next_arr: Array[FmvQteWindow] = []
		if next:
			next_arr.assign(next)

		var old_snap := _windows.duplicate()

		if Engine.is_editor_hint():
			_disconnect_qte_signals(old_snap)

		_windows.clear()
		_windows.append_array(next_arr)

		if Engine.is_editor_hint():
			_connect_qte_signals(_windows)
			_editor_emit_changed_if_needed()

	get:
		return _windows
