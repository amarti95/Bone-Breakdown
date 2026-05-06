extends Resource
class_name FmvGameManifest

@export var rooms: Array[FmvRoom] = []
# Defines the default progression order. If a room's `next_room_id` is empty,
# we advance to the next id in this list (wrapping to the start).
@export var room_order: Array[String] = []
@export var start_room_id: String = ""
@export var default_fail_room_id: String = ""
@export var default_fail_clip_id: String = ""
