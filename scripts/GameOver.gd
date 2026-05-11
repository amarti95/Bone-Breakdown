extends Control

@export var main_menu_scene_path: String = "res://scenes/MainMenu.tscn"

@onready var main_menu_button: Button = %MainMenuButton
@onready var quit_button: Button = %QuitButton


func _ready() -> void:
	main_menu_button.pressed.connect(_on_main_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	main_menu_button.grab_focus()


func _on_main_menu_pressed() -> void:
	if main_menu_scene_path.is_empty():
		push_error("GameOver: main_menu_scene_path is empty.")
		return
	get_tree().change_scene_to_file(main_menu_scene_path)


func _on_quit_pressed() -> void:
	get_tree().quit()
