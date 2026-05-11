extends RefCounted
class_name QteInputKeyIconLibrary

const ATLAS: Texture2D = preload("res://Assets/ui/keyboard_keys_transparent.png")

const _REGIONS: Dictionary = {
	FmvQteWindow.Action.UP: Rect2(35, 4, 28, 27),
	FmvQteWindow.Action.DOWN: Rect2(35, 32, 28, 27),
	FmvQteWindow.Action.LEFT: Rect2(4, 32, 28, 27),
	FmvQteWindow.Action.RIGHT: Rect2(66, 32, 28, 27),
	FmvQteWindow.Action.ACTION: Rect2(97, 32, 151, 27),
}


static func region_for_action(action: int) -> Rect2:
	return _REGIONS.get(action, Rect2())


static func texture_for_action(action: int) -> Texture2D:
	var region := region_for_action(action)
	if region.size == Vector2.ZERO:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = ATLAS
	atlas.region = region
	return atlas


static func display_size_for_action(action: int, target_height: float) -> Vector2:
	var region := region_for_action(action)
	if region.size.y <= 0.0:
		return Vector2.ZERO
	var scale := target_height / region.size.y
	return region.size * scale
