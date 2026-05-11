extends Control

const _SCRUB_FINE_STEP_S := 1.0 / 24.0
const _SCRUB_COARSE_STEP_S := 0.25
const _GAME_OVER_SCENE_PATH := "res://scenes/GameOver.tscn"

@export var manifest: FmvGameManifest

## Subtracted from the **integrated playback clock** described below (not raw `stream_position`). Increase if prompts still feel early vs picture (~0.12–0.28 typical with post-FX).
@export var qte_timeline_lag_compensation_s: float = 0.08

## Wall-clock hold after switching clips before the playback clock advances. Stops `_process(delta)` running ahead of the first decoded video frame.
@export var qte_wall_grace_after_clip_switch_s: float = 0.05

## If non-empty after maps are built, the player starts here instead of normal game progression (inspector only).
@export var debug_start_clip_id: String = ""

## Natural clip endings replay the **same clip** instead of advancing rooms (success branching and explicit `on_finish_next_clip_id` still run).
@export var qte_test_mode: bool = false

## F2 clip browser, P pause, comma/period nudge. Disable for shipped builds when you expose FmvPlayer directly.
@export var enable_qte_dev_tools: bool = true

## Top-right HUD: current clip id and integrated playback clock (matches QTE `start_time_s` authoring).
@export var show_clip_time_overlay: bool = true

## Height of the keyboard-key prompt shown during QTE windows.
@export var prompt_icon_height: float = 96.0

@onready var overlay: CanvasLayer = $Overlay
@onready var video: VideoStreamPlayer = $Video
@onready var prompt_root: Control = $Overlay/Prompt
@onready var prompt_icon: TextureRect = $Overlay/Prompt/CenterContainer/PromptIcon
@onready var debug_label: Label = $Overlay/DebugLabel
@onready var clip_time_hud: Control = $Overlay/ClipTimeHud
@onready var clip_time_label: Label = $Overlay/ClipTimeHud/ClipTimeLabel
@onready var lives_label: Label = $Overlay/LivesHud/LivesLabel

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
var _pending_game_over_after_clip: bool = false
var _clip_to_room_id: Dictionary = {}

var _clip_browser: Control
var _clip_list: ItemList
var _clip_browser_open: bool = false

# `VideoStreamPlayer.stream_position` is unreliable for QTE authoring (often wrong per-codec / after stream swaps).
# We drive manifest windows off integrated playback time: advances with frame delta × speed_scale while unpaused & playing,
# freezes when paused (Dragon's Lair paused QTEs), and bumps with scrub hotkeys — matching how edit timelines relate to playback.
var _clip_playback_accum_s: float = 0.0
var _qte_clock_wall_resume_usec: int = 0


func _ready() -> void:
	if manifest == null:
		push_error("FmvPlayer: missing manifest resource (set it in Inspector).")
		return
	_build_maps_from_manifest()

	var entry_clip_id := ""
	if not debug_start_clip_id.is_empty() and _clip_map.has(debug_start_clip_id):
		entry_clip_id = debug_start_clip_id
		_current_room_id = String(_clip_to_room_id.get(debug_start_clip_id, manifest.start_room_id))
	else:
		_current_room_id = manifest.start_room_id
		entry_clip_id = _get_room_start_clip_id(_current_room_id)

	if entry_clip_id.is_empty():
		push_error("FmvPlayer: no valid clip to play (debug_start_clip_id='%s')." % debug_start_clip_id)
		return

	prompt_root.visible = false
	debug_label.visible = false

	if clip_time_hud != null:
		clip_time_hud.visible = show_clip_time_overlay

	if not GameLives.lives_changed.is_connected(_on_lives_changed):
		GameLives.lives_changed.connect(_on_lives_changed)
	_update_lives_hud()

	video.finished.connect(_on_video_finished)
	_play_clip(entry_clip_id)
	_setup_clip_browser()


func _process(_delta: float) -> void:
	if video.stream == null:
		return
	if _should_advance_clip_playback_clock():
		var d := minf(_delta, 0.1)
		var rate := video.speed_scale
		if rate <= 0.0:
			rate = 1.0
		_clip_playback_accum_s += d * rate

	_update_clip_time_overlay()

	var debug_tools_active := (
			_clip_browser_open
			or video.paused
			or enable_qte_dev_tools and qte_test_mode
			or enable_qte_dev_tools and _debug_visible
			or enable_qte_dev_tools and video.stream != null and not video.is_playing() and not video.paused
	)
	if not video.is_playing() and not _qte_open and not video.paused and not debug_tools_active:
		return

	if Input.is_action_just_pressed("ui_cancel"):
		if _clip_browser_open:
			_close_clip_browser()
			return
		get_tree().quit()

	if Input.is_action_just_pressed("debug_toggle"):
		_debug_visible = not _debug_visible
		debug_label.visible = _debug_visible

	if Input.is_action_pressed("debug_scrub"):
		if Input.is_action_just_pressed("qte_right"):
			_seek_relative(_SCRUB_COARSE_STEP_S)
		elif Input.is_action_just_pressed("qte_left"):
			_seek_relative(-_SCRUB_COARSE_STEP_S)

	var t := _get_qte_timeline_s()
	_update_window_state(t)
	_update_debug(t)


func _input(event: InputEvent) -> void:
	if not enable_qte_dev_tools:
		return

	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		if key.physical_keycode == KEY_COMMA:
			_seek_relative(-_SCRUB_COARSE_STEP_S if key.shift_pressed else -_SCRUB_FINE_STEP_S)
			get_viewport().set_input_as_handled()
		elif key.physical_keycode == KEY_PERIOD:
			_seek_relative(_SCRUB_COARSE_STEP_S if key.shift_pressed else _SCRUB_FINE_STEP_S)
			get_viewport().set_input_as_handled()
		elif key.physical_keycode == KEY_F2:
			_toggle_clip_browser()
			get_viewport().set_input_as_handled()
		elif key.physical_keycode == KEY_P and not _clip_browser_open:
			video.paused = not video.paused
			get_viewport().set_input_as_handled()

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

	_clip_playback_accum_s = 0.0
	var grace_s := maxf(qte_wall_grace_after_clip_switch_s, 0.0)
	_qte_clock_wall_resume_usec = Time.get_ticks_usec() + int(grace_s * 1_000_000.0)

	video.stop()
	video.stream = clip.video
	video.stream_position = 0.0

	video.play()
	video.speed_scale = 1.0
	video.paused = false
	_ignore_finished = false


## Raw engine clock (cross-clip offsets not normalized). Used for scrubbing only.
func _get_engine_stream_time_s() -> float:
	return float(video.stream_position)


func _should_advance_clip_playback_clock() -> bool:
	if video.paused:
		return false
	if Time.get_ticks_usec() < _qte_clock_wall_resume_usec:
		return false
	return video.is_playing()


## Logical seconds into current clip used for manifest `start_time_s` / `end_time_s` (see `_clip_playback_accum_s`).
func _get_clip_local_time_s() -> float:
	return _clip_playback_accum_s


## Timeline used for manifest `start_time_s` / `end_time_s` (clip-local, then lag compensation vs picture).
func _get_qte_timeline_s() -> float:
	return maxf(0.0, _get_clip_local_time_s() - qte_timeline_lag_compensation_s)


func _format_clip_elapsed_s(t_s: float) -> String:
	var m := int(floor(t_s / 60.0))
	var secs := float(fmod(t_s, 60.0))
	return "%02d:%05.2f" % [m, secs]


func _update_clip_time_overlay() -> void:
	if clip_time_label == null or clip_time_hud == null:
		return
	if not show_clip_time_overlay:
		clip_time_hud.visible = false
		return
	clip_time_hud.visible = true
	var cid := _current_clip_id if not _current_clip_id.is_empty() else "—"
	var q := _get_qte_timeline_s()
	clip_time_label.text = "%s\nplayback %s\nQTE −lag %s" % [cid, _format_clip_elapsed_s(_clip_playback_accum_s), _format_clip_elapsed_s(q)]


func _seek_relative(delta_s: float) -> void:
	var t := maxf(_get_engine_stream_time_s() + delta_s, 0.0)
	video.stream_position = t
	_clip_playback_accum_s = maxf(0.0, _clip_playback_accum_s + delta_s)
	# Seeking past the end stops playback; unpause+nudge resumes inspection in dev workflows.
	if enable_qte_dev_tools and video.stream != null and not video.paused and not video.is_playing():
		video.play()

func _restore_playback_normal() -> void:
	video.paused = false
	video.speed_scale = 1.0

func _begin_qte(w: FmvQteWindow) -> void:
	_active_window = w
	_window_resolved = false
	_qte_open = true

	_set_prompt_for_action(w.required_action)
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
	var windows_ordered: Array = clip.windows.duplicate()
	windows_ordered.sort_custom(func(a: Variant, b: Variant) -> bool:
		var wa := a as FmvQteWindow
		var wb := b as FmvQteWindow
		if wa == null:
			return true
		if wb == null:
			return false
		return wa.start_time_s < wb.start_time_s
	)

	for w_any in windows_ordered:
		var w: FmvQteWindow = w_any as FmvQteWindow
		if w == null:
			continue
		var key := "%s|%0.3f|%0.3f" % [_current_clip_id, w.start_time_s, w.end_time_s]
		if _fired_windows.has(key):
			continue
		if t >= w.start_time_s:
			_fired_windows[key] = true
			_begin_qte(w)
			return

func _consume_qte_action() -> int:
	if _clip_browser_open:
		return -1
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
	var w: FmvQteWindow = _active_window
	_window_resolved = true
	_restore_playback_normal()
	_end_qte_keep_playing()
	_active_window = null

	GameLives.lose_life()
	_update_lives_hud()
	_pending_game_over_after_clip = not GameLives.has_lives_remaining()

	var next_id := w.fail_next_clip_id if w != null else ""
	if next_id == "":
		var fallback_room := manifest.default_fail_room_id if manifest != null else _current_room_id
		var fallback_clip := manifest.default_fail_clip_id if manifest != null else ""
		if fallback_clip.is_empty():
			fallback_clip = _get_room_start_clip_id(fallback_room)
		next_id = fallback_clip
	if next_id.is_empty():
		push_error("FmvPlayer: no failure clip to play for room '%s'." % _current_room_id)
		_go_to_game_over()
		return
	_play_clip(next_id)


func _on_lives_changed(_lives: int) -> void:
	_update_lives_hud()


func _update_lives_hud() -> void:
	if lives_label == null:
		return
	lives_label.text = "Lives: %d" % GameLives.lives


func _go_to_game_over() -> void:
	_pending_game_over_after_clip = false
	_close_clip_browser()
	prompt_root.visible = false
	video.stop()
	get_tree().change_scene_to_file(_GAME_OVER_SCENE_PATH)

func _set_prompt_for_action(action: int) -> void:
	if prompt_icon == null:
		return
	var icon := QteInputKeyIconLibrary.texture_for_action(action)
	prompt_icon.texture = icon
	if icon == null:
		prompt_icon.custom_minimum_size = Vector2.ZERO
		return
	prompt_icon.custom_minimum_size = QteInputKeyIconLibrary.display_size_for_action(action, prompt_icon_height)


func _action_to_text(a: int) -> String:
	match a:
		FmvQteWindow.Action.UP:
			return "W"
		FmvQteWindow.Action.DOWN:
			return "S"
		FmvQteWindow.Action.LEFT:
			return "A"
		FmvQteWindow.Action.RIGHT:
			return "D"
		FmvQteWindow.Action.ACTION:
			return "SPACE"
		_:
			return "?"

func _update_debug(t: float) -> void:
	if not _debug_visible:
		return
	var win_txt := "-"
	if _active_window != null:
		var mode := "pause" if _active_window.pause else ("slow %.2f" % _active_window.slow_scale)
		win_txt = "%0.2f-%0.2f (%s) %s" % [_active_window.start_time_s, _active_window.end_time_s, _action_to_text(_active_window.required_action), mode]
	var eng := _get_engine_stream_time_s()
	var loc := _get_clip_local_time_s()
	debug_label.text = "clip=%s qte=%0.2f playback=%0.2f stream=%0.2f lag=%0.3f | %s | paused=%s spd=%0.2f qte_open=%s" % [
		_current_clip_id,
		t,
		loc,
		eng,
		qte_timeline_lag_compensation_s,
		win_txt,
		str(video.paused),
		float(video.speed_scale),
		str(_qte_open),
	]

func _on_video_finished() -> void:
	if _ignore_finished:
		return
	if _pending_game_over_after_clip:
		var finished_clip: FmvClip = _clip_map.get(_current_clip_id)
		var next_id := finished_clip.on_finish_next_clip_id if finished_clip != null else ""
		var room_start := _get_room_start_clip_id(_current_room_id)
		if next_id.is_empty() or next_id == room_start:
			_go_to_game_over()
			return
		_play_clip(next_id)
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
	elif qte_test_mode:
		next_id = _current_clip_id
	else:
		_current_room_id = _get_next_room_id(_current_room_id)
		next_id = _get_room_start_clip_id(_current_room_id)
	_play_clip(next_id)

func _build_maps_from_manifest() -> void:
	_room_map.clear()
	_clip_map.clear()
	_clip_to_room_id.clear()
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
			_clip_to_room_id[c.id] = r.id


func _ordered_room_ids() -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for rid_any in manifest.room_order:
		var rid := String(rid_any)
		if rid.is_empty() or seen.has(rid):
			continue
		if _room_map.has(rid):
			out.append(rid)
			seen[rid] = true
	for r_any in manifest.rooms:
		var rr: FmvRoom = r_any
		if rr == null or rr.id.is_empty():
			continue
		if seen.has(rr.id):
			continue
		out.append(rr.id)
		seen[rr.id] = true
	return out


func _setup_clip_browser() -> void:
	if _clip_browser != null:
		return
	_clip_browser = PanelContainer.new()
	_clip_browser.name = "ClipBrowser"
	_clip_browser.visible = false
	_clip_browser.mouse_filter = Control.MOUSE_FILTER_STOP
	_clip_browser.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_clip_browser.anchor_right = 0.0
	_clip_browser.anchor_bottom = 0.0
	_clip_browser.offset_left = 16.0
	_clip_browser.offset_top = 140.0
	_clip_browser.offset_right = 16.0 + 440.0
	_clip_browser.offset_bottom = 140.0 + 520.0
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var hint := Label.new()
	hint.text = "Dev: F2 open/close • P pause • comma/period −/+ 1 frame (Shift=0.25s) • Shift+debug_scrub+A/D coarse"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(hint)
	_clip_list = ItemList.new()
	_clip_list.custom_minimum_size = Vector2(400, 420)
	_clip_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_clip_list.allow_reselect = true
	vb.add_child(_clip_list)
	_clip_browser.add_child(vb)
	overlay.add_child(_clip_browser)
	overlay.move_child(_clip_browser, overlay.get_child_count() - 1)
	_clip_list.item_clicked.connect(_on_clip_browser_clicked)


func _repopulate_clip_browser_list() -> void:
	if _clip_list == null:
		return
	_clip_list.clear()
	for rid in _ordered_room_ids():
		var room: FmvRoom = _room_map.get(rid)
		if room == null:
			continue
		var rlabel := rid
		if room.display_name != "":
			rlabel = "%s [%s]" % [room.display_name, rid]
		for c_any in room.clips:
			var cc: FmvClip = c_any
			if cc == null or cc.id.is_empty():
				continue
			var line := "%s  │  %s" % [rlabel, cc.id]
			var idx := _clip_list.item_count
			_clip_list.add_item(line)
			_clip_list.set_item_metadata(idx, cc.id)


func _on_clip_browser_clicked(index: int, _at_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	if _clip_list == null or index < 0:
		return
	var meta_any = _clip_list.get_item_metadata(index)
	var cid := str(meta_any).strip_edges()
	if cid.is_empty():
		return
	_close_clip_browser()
	_jump_to_clip(cid)


func _jump_to_clip(clip_id: String) -> void:
	if not _clip_map.has(clip_id):
		push_error("FmvPlayer: unknown clip '%s'" % clip_id)
		return
	if _clip_to_room_id.has(clip_id):
		_current_room_id = String(_clip_to_room_id[clip_id])
	_pending_game_over_after_clip = false
	_play_clip(clip_id)


func _toggle_clip_browser() -> void:
	if _clip_browser == null:
		_setup_clip_browser()
	if _clip_browser_open:
		_close_clip_browser()
	else:
		_open_clip_browser()


func _open_clip_browser() -> void:
	if _clip_browser == null:
		_setup_clip_browser()
	_clip_browser_open = true
	_clip_browser.visible = true
	_repopulate_clip_browser_list()
	video.paused = true
	call_deferred("_grab_clip_list_focus")


func _grab_clip_list_focus() -> void:
	if _clip_list != null and _clip_list.is_visible_in_tree():
		_clip_list.grab_focus()


func _close_clip_browser() -> void:
	_clip_browser_open = false
	if _clip_browser != null:
		_clip_browser.visible = false

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
