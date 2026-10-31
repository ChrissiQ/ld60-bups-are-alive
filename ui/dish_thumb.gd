class_name DishThumb
extends Texture2D
## A dish's small picture as a texture, for a button's icon: the dish (its agar and rim) and over it the dish's tile of the thumbnails'
## atlas (DishDrawing.draw_thumbnail). The strip gives one to each of its tabs and points it at another dish's tile as the tab is reused.

var size := 44  ## pixels across
var atlas: Texture2D = null  ## the thumbnails' atlas (null: the dish is drawn without its bups)
var region := Rect2()  ## the dish's tile in it (texels)


func _get_width() -> int:
	return size


func _get_height() -> int:
	return size


func _has_alpha() -> bool:
	return true


func _draw(to_canvas_item: RID, pos: Vector2, modulate: Color, _transpose: bool) -> void:
	DishDrawing.draw_thumbnail(to_canvas_item, Rect2(pos, Vector2(size, size)), atlas, region, modulate)


func _draw_rect(to_canvas_item: RID, rect: Rect2, _tile: bool, modulate: Color, _transpose: bool) -> void:
	DishDrawing.draw_thumbnail(to_canvas_item, rect, atlas, region, modulate)


func _draw_rect_region(to_canvas_item: RID, rect: Rect2, _src_rect: Rect2, modulate: Color, _transpose: bool, _clip_uv: bool) -> void:
	DishDrawing.draw_thumbnail(to_canvas_item, rect, atlas, region, modulate)
