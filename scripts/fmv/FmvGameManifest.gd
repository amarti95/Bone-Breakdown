@tool
extends Resource
class_name FmvGameManifest

func _editor_emit_changed_if_needed() -> void:
	if Engine.is_editor_hint():
		emit_changed()


func _on_nested_room_changed() -> void:
	_editor_emit_changed_if_needed()


func _disconnect_room_signals(room_list: Array) -> void:
	for r_any in room_list:
		var rm := r_any as Resource
		if rm != null and rm.changed.is_connected(_on_nested_room_changed):
			rm.changed.disconnect(_on_nested_room_changed)


func _connect_room_signals(room_list: Array) -> void:
	for r_any in room_list:
		var rm := r_any as Resource
		if rm != null and not rm.changed.is_connected(_on_nested_room_changed):
			rm.changed.connect(_on_nested_room_changed)


func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_POSTINITIALIZE:
		call_deferred("_editor_sync_room_signals")


func _editor_sync_room_signals() -> void:
	if not Engine.is_editor_hint():
		return
	_disconnect_room_signals(_rooms)
	_connect_room_signals(_rooms)


var _rooms: Array[FmvRoom] = []

## Default progression order. If a room's `next_room_id` is empty, we advance to the next id here (wrapping to the start).
@export var rooms: Array[FmvRoom] = []:
	set(next):
		var next_arr: Array[FmvRoom] = []
		if next:
			next_arr.assign(next)

		var old_snap := _rooms.duplicate()

		if Engine.is_editor_hint():
			_disconnect_room_signals(old_snap)

		_rooms.clear()
		_rooms.append_array(next_arr)

		if Engine.is_editor_hint():
			_connect_room_signals(_rooms)
			_editor_emit_changed_if_needed()

	get:
		return _rooms


var _room_order: Array[String] = []

@export var room_order: Array[String] = []:
	set(v):
		var next := v if v else []
		_room_order.clear()
		_room_order.append_array(next)
		_editor_emit_changed_if_needed()

	get:
		return _room_order


@export var start_room_id: String = "":
	set(v):
		if start_room_id == v:
			return
		start_room_id = v
		_editor_emit_changed_if_needed()


@export var default_fail_room_id: String = "":
	set(v):
		if default_fail_room_id == v:
			return
		default_fail_room_id = v
		_editor_emit_changed_if_needed()


@export var default_fail_clip_id: String = "":
	set(v):
		if default_fail_clip_id == v:
			return
		default_fail_clip_id = v
		_editor_emit_changed_if_needed()
