extends Control

const Manifest := preload("res://scripts/FmvManifest.gd")

@onready var video: VideoStreamPlayer = $Video
@onready var prompt_root: Control = $Overlay/Prompt
@onready var prompt_label: Label = $Overlay/Prompt/PromptLabel
@onready var debug_label: Label = $Overlay/DebugLabel

var _data: Dictionary
var _clips: Dictionary
var _current_clip_id: String
var _active_window: Manifest.QteWindow
var _window_resolved: bool = false
var _debug_visible: bool = false
var _qte_open: bool = false
var _qte_reaction_deadline_usec: int = 0
var _fired_windows: Dictionary = {}
var _ignore_finished: bool = false
var _pending_success_next_clip_id: String = ""

func _ready() -> void:
	_data = Manifest.build_default()
	_clips = _data["clips"]
	_current_clip_id = _data["start_clip_id"]

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

	var clip: Manifest.Clip = _clips.get(_current_clip_id)
	if clip == null:
		push_error("Unknown clip id: %s" % _current_clip_id)
		_ignore_finished = false
		return

	var stream := load(clip.video_path)
	if stream == null:
		push_error("Failed to load video: %s" % clip.video_path)
		_ignore_finished = false
		return

	video.stop()
	video.stream = stream
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

func _begin_qte(w: Manifest.QteWindow) -> void:
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
	var clip: Manifest.Clip = _clips.get(_current_clip_id)
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
		var w: Manifest.QteWindow = w_any
		var key := "%s|%0.3f|%0.3f" % [_current_clip_id, w.start_time_s, w.end_time_s]
		if _fired_windows.has(key):
			continue
		if t >= w.start_time_s:
			_fired_windows[key] = true
			_begin_qte(w)
			return

func _consume_qte_action() -> int:
	# Returns one of Manifest.Action, or -1 if no input this frame.
	if Input.is_action_just_pressed("qte_up"):
		return Manifest.Action.UP
	if Input.is_action_just_pressed("qte_down"):
		return Manifest.Action.DOWN
	if Input.is_action_just_pressed("qte_left"):
		return Manifest.Action.LEFT
	if Input.is_action_just_pressed("qte_right"):
		return Manifest.Action.RIGHT
	if Input.is_action_just_pressed("qte_action"):
		return Manifest.Action.ACTION
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
		next_id = _data.get("default_fail_clip_id", _data.get("start_clip_id", ""))
	_play_clip(next_id)

func _action_to_text(a: int) -> String:
	match a:
		Manifest.Action.UP:
			return "UP"
		Manifest.Action.DOWN:
			return "DOWN"
		Manifest.Action.LEFT:
			return "LEFT"
		Manifest.Action.RIGHT:
			return "RIGHT"
		Manifest.Action.ACTION:
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
	var clip: Manifest.Clip = _clips.get(_current_clip_id)
	var next_id := ""
	if clip != null and clip.on_finish_next_clip_id != "":
		next_id = clip.on_finish_next_clip_id
	else:
		next_id = str(_data.get("start_clip_id", _current_clip_id))
	_play_clip(next_id)
