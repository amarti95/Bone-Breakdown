extends Resource
class_name FmvQteWindow

enum Action {
	UP,
	DOWN,
	LEFT,
	RIGHT,
	ACTION,
}

@export var start_time_s: float = 0.0
@export var end_time_s: float = 0.0
@export var required_action: Action = Action.ACTION

# If true, freeze video during the reaction window (Dragon's Lair style).
@export var pause: bool = true

# Used when pause is false: slow the video (1.0 = normal). Ignored if pause is true.
@export var slow_scale: float = 0.35

# If > 0 and pause is true, the player has this many *real-time* seconds to act after the prompt shows.
# If 0, we default to (end_time_s - start_time_s).
@export var reaction_time_s: float = 0.75

@export var success_next_clip_id: String = ""
@export var fail_next_clip_id: String = ""

