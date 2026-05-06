extends Resource
class_name FmvClip

@export var id: String = ""
@export var video: VideoStream
@export var on_finish_next_clip_id: String = ""
@export var windows: Array[FmvQteWindow] = []
