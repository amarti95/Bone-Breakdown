@tool
extends Resource
class_name FmvRoom

func _editor_emit_changed_if_needed() -> void:
	if Engine.is_editor_hint():
		emit_changed()


func _on_nested_clip_changed() -> void:
	_editor_emit_changed_if_needed()


func _disconnect_clip_signals(clip_list: Array) -> void:
	for c_any in clip_list:
		var c := c_any as Resource
		if c != null and c.changed.is_connected(_on_nested_clip_changed):
			c.changed.disconnect(_on_nested_clip_changed)


func _connect_clip_signals(clip_list: Array) -> void:
	for c_any in clip_list:
		var c := c_any as Resource
		if c != null and not c.changed.is_connected(_on_nested_clip_changed):
			c.changed.connect(_on_nested_clip_changed)


func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_POSTINITIALIZE:
		call_deferred("_editor_sync_clip_signals")


func _editor_sync_clip_signals() -> void:
	if not Engine.is_editor_hint():
		return
	_disconnect_clip_signals(_clips)
	_connect_clip_signals(_clips)


@export var id: String = "":
	set(v):
		if id == v:
			return
		id = v
		_editor_emit_changed_if_needed()


@export var display_name: String = "":
	set(v):
		if display_name == v:
			return
		display_name = v
		_editor_emit_changed_if_needed()


var _clips: Array[FmvClip] = []

@export var clips: Array[FmvClip] = []:
	set(next):
		var next_arr: Array[FmvClip] = []
		if next:
			next_arr.assign(next)

		var old_snap := _clips.duplicate()

		if Engine.is_editor_hint():
			_disconnect_clip_signals(old_snap)

		_clips.clear()
		_clips.append_array(next_arr)

		if Engine.is_editor_hint():
			_connect_clip_signals(_clips)
			_editor_emit_changed_if_needed()

	get:
		return _clips


@export var start_clip_id: String = "":
	set(v):
		if start_clip_id == v:
			return
		start_clip_id = v
		_editor_emit_changed_if_needed()


@export var next_room_id: String = "":
	set(v):
		if next_room_id == v:
			return
		next_room_id = v
		_editor_emit_changed_if_needed()

