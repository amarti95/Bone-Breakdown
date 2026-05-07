extends Control

@export var start_scene_path: String = "res://scenes/FmvPlayer.tscn"

@onready var start_button: Button = %StartButton
@onready var quit_button: Button = %QuitButton

func _ready() -> void:
	start_button.pressed.connect(_on_start_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	start_button.grab_focus()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_quit_pressed()

func _on_start_pressed() -> void:
	if start_scene_path.is_empty():
		push_error("MainMenu: start_scene_path is empty.")
		return
	get_tree().change_scene_to_file(start_scene_path)

func _on_quit_pressed() -> void:
	get_tree().quit()
