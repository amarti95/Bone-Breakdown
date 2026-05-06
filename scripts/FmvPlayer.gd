extends Control

const FmvGameManifest := preload("res://scripts/fmv/FmvGameManifest.gd")
const FmvRoom := preload("res://scripts/fmv/FmvRoom.gd")
const FmvClip := preload("res://scripts/fmv/FmvClip.gd")
const FmvQteWindow := preload("res://scripts/fmv/FmvQteWindow.gd")

@export var manifest: FmvGameManifest

@onready var video: VideoStreamPlayer = $Video
@onready var prompt_root: Control = $Overlay/Prompt
@onready var prompt_label: Label = $Overlay/Prompt/PromptLabel
@onready var debug_label: Label = $Overlay/DebugLabel

var _room_map: Dictionary = {}
var _clip_map: Dictionary = {}
var _current_room_id: String = ""
var _current_clip_id: String
var _active_window: FmvQteWindow
var _window_resolved: bool = false
var _debug_visible: bool = false
var _qte_open: bool = false
var _qte_reaction_deadline_usec: int = 0
var _fired_windows: Dictionary = {}
var _ignore_finished: bool = false
var _pending_success_next_clip_id: String = ""

func _ready() -> void:
	if manifest == null:
		push_error("FmvPlayer: missing manifest resource (set it in Inspector).")
		return
	_build_maps_from_manifest()
	_current_room_id = manifest.start_room_id
	_current_clip_id = _get_room_start_clip_id(_current_room_id)
	if _current_clip_id.is_empty():
		push_error("FmvPlayer: no start clip for room '%s'." % _current_room_id)
		return

	prompt_root.visible = false
	debug_label.visible = false

	video.finished.connect(_on_video_finished)
	_play_clip(_current_clip_id)

func _process(_delta: float) -> void:
	if video.stream == null:
		return
	# Note: some builds report `is_playing() == false` while `paused == true`.
	# We must keep processing during active QTE prompts or input/branching won't happen.
	if not video.is_playing() and not _qte_open and not video.paused:
		return

	if Input.is_action_just_pressed("ui_cancel"):
		get_tree().quit()

	if Input.is_action_just_pressed("debug_toggle"):
		_debug_visible = not _debug_visible
		debug_label.visible = _debug_visible

	if Input.is_action_pressed("debug_scrub"):
		if Input.is_action_just_pressed("qte_right"):
			_seek_relative(0.25)
		elif Input.is_action_just_pressed("qte_left"):
			_seek_relative(-0.25)

	var t := _get_playback_time_s()
	_update_window_state(t)
	_update_debug(t)

func _play_clip(clip_id: String) -> void:
	# `finished` can fire spuriously around stream changes; never treat that as an end-of-clip transition.
	_ignore_finished = true
	_restore_playback_normal()
	_current_clip_id = clip_id
	_active_window = null
	_window_resolved = false
	prompt_root.visible = false
	_qte_open = false
	_qte_reaction_deadline_usec = 0
	_fired_windows.clear()
	_pending_success_next_clip_id = ""

	var clip: FmvClip = _clip_map.get(_current_clip_id)
	if clip == null:
		push_error("Unknown clip id: %s" % _current_clip_id)
		_ignore_finished = false
		return

	if clip.video == null:
		push_error("Missing video for clip: %s" % _current_clip_id)
		_ignore_finished = false
		return

	video.stop()
	video.stream = clip.video
	video.play()
	video.speed_scale = 1.0
	video.paused = false
	_ignore_finished = false

func _get_playback_time_s() -> float:
	return float(video.stream_position)

func _seek_relative(delta_s: float) -> void:
	var t := _get_playback_time_s() + delta_s
	video.stream_position = maxf(t, 0.0)

func _restore_playback_normal() -> void:
	video.paused = false
	video.speed_scale = 1.0

func _begin_qte(w: FmvQteWindow) -> void:
	_active_window = w
	_window_resolved = false
	_qte_open = true

	prompt_label.text = _action_to_text(w.required_action)
	prompt_root.visible = true

	if w.pause:
		video.paused = true
		video.speed_scale = 0.0
		var rt := w.reaction_time_s
		if rt <= 0.0:
			rt = maxf(0.0001, w.end_time_s - w.start_time_s)
		rt = maxf(0.0001, rt)
		_qte_reaction_deadline_usec = Time.get_ticks_usec() + int(rt * 1000000.0)
	else:
		video.paused = false
		var ss := w.slow_scale
		if ss <= 0.0:
			ss = 1.0
		video.speed_scale = ss
		_qte_reaction_deadline_usec = 0

func _end_qte_keep_playing() -> void:
	_qte_open = false
	_qte_reaction_deadline_usec = 0
	prompt_root.visible = false
	video.paused = false
	video.speed_scale = 1.0

func _update_window_state(t: float) -> void:
	var clip: FmvClip = _clip_map.get(_current_clip_id)
	if clip == null:
		return

	if _qte_open and _active_window != null:
		var w := _active_window

		if _window_resolved:
			return

		# Timeout rules:
		# - paused QTE uses real-time reaction window
		# - non-paused QTE uses video timeline end
		var timed_out := false
		if w.pause:
			timed_out = Time.get_ticks_usec() >= _qte_reaction_deadline_usec
		else:
			timed_out = t > w.end_time_s

		var action_pressed: int = _consume_qte_action()
		if action_pressed >= 0:
			if action_pressed == w.required_action:
				_commit_success_pending()
			else:
				_branch_fail()
			return

		if timed_out:
			_branch_fail()
		return

	# Arm QTE once its start time is crossed (even if we only pause/react briefly).
	for w_any in clip.windows:
		var w: FmvQteWindow = w_any
		var key := "%s|%0.3f|%0.3f" % [_current_clip_id, w.start_time_s, w.end_time_s]
		if _fired_windows.has(key):
			continue
		if t >= w.start_time_s:
			_fired_windows[key] = true
			_begin_qte(w)
			return

func _consume_qte_action() -> int:
	# Returns one of FmvQteWindow.Action, or -1 if no input this frame.
	if Input.is_action_just_pressed("qte_up"):
		return FmvQteWindow.Action.UP
	if Input.is_action_just_pressed("qte_down"):
		return FmvQteWindow.Action.DOWN
	if Input.is_action_just_pressed("qte_left"):
		return FmvQteWindow.Action.LEFT
	if Input.is_action_just_pressed("qte_right"):
		return FmvQteWindow.Action.RIGHT
	if Input.is_action_just_pressed("qte_action"):
		return FmvQteWindow.Action.ACTION
	return -1

func _commit_success_pending() -> void:
	# Let the current clip finish playing out; transition on `finished`.
	_window_resolved = true
	var next_id := _active_window.success_next_clip_id
	_pending_success_next_clip_id = next_id
	_active_window = null
	_restore_playback_normal()
	_end_qte_keep_playing()

func _branch_fail() -> void:
	_window_resolved = true
	_restore_playback_normal()
	_end_qte_keep_playing()
	var next_id := _active_window.fail_next_clip_id
	if next_id == "":
		# Use manifest defaults if the window doesn't specify a fail target.
		var fallback_room := manifest.default_fail_room_id if manifest != null else _current_room_id
		var fallback_clip := manifest.default_fail_clip_id if manifest != null else ""
		if fallback_clip.is_empty():
			fallback_clip = _get_room_start_clip_id(fallback_room)
		next_id = fallback_clip
	_play_clip(next_id)

func _action_to_text(a: int) -> String:
	match a:
		FmvQteWindow.Action.UP:
			return "UP"
		FmvQteWindow.Action.DOWN:
			return "DOWN"
		FmvQteWindow.Action.LEFT:
			return "LEFT"
		FmvQteWindow.Action.RIGHT:
			return "RIGHT"
		FmvQteWindow.Action.ACTION:
			return "ACTION"
		_:
			return "?"

func _update_debug(t: float) -> void:
	if not _debug_visible:
		return
	var win_txt := "-"
	if _active_window != null:
		var mode := "pause" if _active_window.pause else ("slow %.2f" % _active_window.slow_scale)
		win_txt = "%0.2f-%0.2f (%s) %s" % [_active_window.start_time_s, _active_window.end_time_s, _action_to_text(_active_window.required_action), mode]
	debug_label.text = "clip=%s  t=%0.2fs  window=%s | paused=%s speed=%0.2f qte=%s" % [
		_current_clip_id,
		t,
		win_txt,
		str(video.paused),
		float(video.speed_scale),
		str(_qte_open),
	]

func _on_video_finished() -> void:
	if _ignore_finished:
		return
	if _pending_success_next_clip_id != "":
		var ok_id := _pending_success_next_clip_id
		_pending_success_next_clip_id = ""
		_play_clip(ok_id)
		return
	var clip: FmvClip = _clip_map.get(_current_clip_id)
	var next_id := ""
	if clip != null and clip.on_finish_next_clip_id != "":
		next_id = clip.on_finish_next_clip_id
	else:
		# Advance to next room (or restart current room) when a clip ends naturally.
		_current_room_id = _get_next_room_id(_current_room_id)
		next_id = _get_room_start_clip_id(_current_room_id)
	_play_clip(next_id)

func _build_maps_from_manifest() -> void:
	_room_map.clear()
	_clip_map.clear()
	for r_any in manifest.rooms:
		var r: FmvRoom = r_any
		if r == null or r.id.is_empty():
			continue
		_room_map[r.id] = r
		for c_any in r.clips:
			var c: FmvClip = c_any
			if c == null or c.id.is_empty():
				continue
			_clip_map[c.id] = c

func _get_room_start_clip_id(room_id: String) -> String:
	var r: FmvRoom = _room_map.get(room_id)
	if r == null:
		return ""
	if not r.start_clip_id.is_empty():
		return r.start_clip_id
	if r.clips.size() > 0 and (r.clips[0] as FmvClip) != null:
		return (r.clips[0] as FmvClip).id
	return ""

func _get_next_room_id(room_id: String) -> String:
	if manifest == null:
		return room_id
	var room: FmvRoom = _room_map.get(room_id)
	if room != null and not room.next_room_id.is_empty():
		return room.next_room_id

	# Fall back to manifest order list.
	var order := manifest.room_order
	if order.size() == 0:
		return room_id
	var idx := order.find(room_id)
	if idx == -1:
		return order[0]
	return order[(idx + 1) % order.size()]
