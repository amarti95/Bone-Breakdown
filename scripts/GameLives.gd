extends Node

signal lives_changed(lives: int)

const MAX_LIVES := 3

var lives: int = MAX_LIVES


func reset_for_new_run() -> void:
	lives = MAX_LIVES
	lives_changed.emit(lives)


func lose_life() -> void:
	lives = maxi(0, lives - 1)
	lives_changed.emit(lives)


func has_lives_remaining() -> bool:
	return lives > 0
