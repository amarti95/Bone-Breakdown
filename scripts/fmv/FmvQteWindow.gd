@tool
extends Resource
class_name FmvQteWindow

enum Action {
	UP,
	DOWN,
	LEFT,
	RIGHT,
	ACTION,
}

func _editor_emit_changed_if_needed() -> void:
	if Engine.is_editor_hint():
		emit_changed()


@export var start_time_s: float = 0.0:
	set(v):
		if is_equal_approx(start_time_s, v):
			return
		start_time_s = v
		_editor_emit_changed_if_needed()

@export var end_time_s: float = 0.0:
	set(v):
		if is_equal_approx(end_time_s, v):
			return
		end_time_s = v
		_editor_emit_changed_if_needed()

@export var required_action: Action = Action.ACTION:
	set(v):
		if required_action == v:
			return
		required_action = v
		_editor_emit_changed_if_needed()

# If true, freeze video during the reaction window (Dragon's Lair style).
@export var pause: bool = true:
	set(v):
		if pause == v:
			return
		pause = v
		_editor_emit_changed_if_needed()

# Used when pause is false: slow the video (1.0 = normal). Ignored if pause is true.
@export var slow_scale: float = 0.35:
	set(v):
		if is_equal_approx(slow_scale, v):
			return
		slow_scale = v
		_editor_emit_changed_if_needed()

# If > 0 and pause is true, the player has this many *real-time* seconds to act after the prompt shows.
# If 0, we default to (end_time_s - start_time_s).
@export var reaction_time_s: float = 0.75:
	set(v):
		if is_equal_approx(reaction_time_s, v):
			return
		reaction_time_s = v
		_editor_emit_changed_if_needed()

@export var success_next_clip_id: String = "":
	set(v):
		if success_next_clip_id == v:
			return
		success_next_clip_id = v
		_editor_emit_changed_if_needed()

@export var fail_next_clip_id: String = "":
	set(v):
		if fail_next_clip_id == v:
			return
		fail_next_clip_id = v
		_editor_emit_changed_if_needed()

