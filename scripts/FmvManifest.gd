extends RefCounted
class_name FmvManifest

enum Action {
	UP,
	DOWN,
	LEFT,
	RIGHT,
	ACTION,
}

class QteWindow:
	var start_time_s: float
	var end_time_s: float
	var required_action: Action
	var success_next_clip_id: String
	var fail_next_clip_id: String
	# If true, freeze video during the reaction window (Dragon's Lair style).
	var pause: bool
	# Used when pause is false: slow the video (1.0 = normal). Ignored if pause is true.
	var slow_scale: float
	# If > 0 and pause is true, the player has this many *real-time* seconds to act after the prompt shows.
	# If 0, timeouts use the video timeline end_time_s (works best when not paused).
	var reaction_time_s: float

	func _init(
		p_start_time_s: float,
		p_end_time_s: float,
		p_required_action: Action,
		p_success_next_clip_id: String,
		p_fail_next_clip_id: String = "",
		p_pause: bool = true,
		p_slow_scale: float = 0.35,
		p_reaction_time_s: float = 0.75
	) -> void:
		start_time_s = p_start_time_s
		end_time_s = p_end_time_s
		required_action = p_required_action
		success_next_clip_id = p_success_next_clip_id
		fail_next_clip_id = p_fail_next_clip_id
		pause = p_pause
		slow_scale = p_slow_scale
		reaction_time_s = p_reaction_time_s

class Clip:
	var id: String
	var video_path: String
	var on_finish_next_clip_id: String
	# Keep this untyped to avoid nested-class generic type identity issues in Godot.
	var windows: Array

	func _init(p_id: String, p_video_path: String, p_windows: Array, p_on_finish_next_clip_id: String = "") -> void:
		id = p_id
		video_path = p_video_path
		windows = p_windows
		on_finish_next_clip_id = p_on_finish_next_clip_id

static func build_default() -> Dictionary:
	var json_path := "res://data/fmv_manifest.json"
	if FileAccess.file_exists(json_path):
		var parsed: Variant = _load_json_file(json_path)
		if typeof(parsed) == TYPE_DICTIONARY:
			return _manifest_from_dict(parsed)

	push_warning("FmvManifest: missing or invalid %s; using embedded fallback." % json_path)
	return _embedded_fallback()

static func _load_json_file(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("FmvManifest: JSON parse error in %s: %s" % [path, json.get_error_message()])
		return null
	return json.data

static func _manifest_from_dict(root: Dictionary) -> Dictionary:
	var start_clip_id: String = str(root.get("start_clip_id", ""))
	var default_fail_clip_id: String = str(root.get("default_fail_clip_id", start_clip_id))

	var clips_out: Dictionary = {}
	var clips_in: Dictionary = root.get("clips", {})
	if typeof(clips_in) != TYPE_DICTIONARY:
		push_error("FmvManifest: invalid clips table")
		return _embedded_fallback()

	for clip_id in clips_in.keys():
		var clip_any: Variant = clips_in[clip_id]
		if typeof(clip_any) != TYPE_DICTIONARY:
			continue
		var cd: Dictionary = clip_any
		var id: String = str(cd.get("id", clip_id))
		var video_path: String = str(cd.get("video_path", ""))
		var on_finish_next_clip_id: String = str(cd.get("on_finish_next_clip_id", ""))

		var windows: Array = []
		var wins_any: Variant = cd.get("windows", [])
		if typeof(wins_any) == TYPE_ARRAY:
			for w_any in wins_any:
				if typeof(w_any) != TYPE_DICTIONARY:
					continue
				var wd: Dictionary = w_any
				var req := action_from_string(str(wd.get("required_action", "")))
				var pause: bool = bool(wd.get("pause", true))
				var slow_scale: float = float(wd.get("slow_scale", 0.35))
				var reaction_time_s: float = float(wd.get("reaction_time_s", 0.75))
				windows.append(
					QteWindow.new(
						float(wd.get("start_time_s", 0.0)),
						float(wd.get("end_time_s", 0.0)),
						req,
						str(wd.get("success_next_clip_id", "")),
						str(wd.get("fail_next_clip_id", "")),
						pause,
						slow_scale,
						reaction_time_s
					)
				)

		clips_out[id] = Clip.new(id, video_path, windows, on_finish_next_clip_id)

	return {
		"start_clip_id": start_clip_id,
		"clips": clips_out,
		"default_fail_clip_id": default_fail_clip_id,
	}

static func action_from_string(s: String) -> Action:
	match s.to_upper():
		"UP":
			return Action.UP
		"DOWN":
			return Action.DOWN
		"LEFT":
			return Action.LEFT
		"RIGHT":
			return Action.RIGHT
		"ACTION":
			return Action.ACTION
		_:
			return Action.ACTION

static func _embedded_fallback() -> Dictionary:
	var clips: Dictionary = {}

	clips["clip1"] = Clip.new(
		"clip1",
		"res://videos/clip1_jump_laser.ogv",
		[
			QteWindow.new(0.90, 1.40, Action.UP, "clip2", "clip1", true, 0.35, 0.75),
		],
		"clip1"
	)

	clips["clip2"] = Clip.new(
		"clip2",
		"res://videos/clip2_duck.ogv",
		[
			QteWindow.new(1.00, 1.60, Action.DOWN, "clip3", "clip2", false, 0.35, 0.0),
		],
		"clip1"
	)

	clips["clip3"] = Clip.new(
		"clip3",
		"res://videos/clip3_headthrow.ogv",
		[
			QteWindow.new(0.80, 1.40, Action.ACTION, "clip4", "clip3", true, 0.35, 0.75),
		],
		"clip1"
	)

	clips["clip4"] = Clip.new(
		"clip4",
		"res://videos/clip4_exit.ogv",
		[],
		"clip1"
	)

	return {
		"start_clip_id": "clip1",
		"clips": clips,
		"default_fail_clip_id": "clip1",
	}
