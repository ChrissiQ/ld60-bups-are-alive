class_name ThumbsInfo
extends RefCounted
## Which shared texture holds the thumbnails' atlas, the publish that wrote it, and where each dish's tile lies in it. The main side gives
## the publish's number back with every use of the texture (WorldClient.texture_bound), so the simulation writes over it only once a newer
## atlas is in use; without that the atlas's textures would all stay taken after SimCore.TEXTURES publishes.

var texture_index := -1  ## the atlas's texture (-1: none yet)
var seq := 0  ## the number of the publish that wrote it (SimCore.publish_seq)
var bytes := PackedByteArray()  ## with ViewRenderer.cpu_handover: the atlas's first `tile_rows` rows of tiles (SimCore.handed), in place of a shared texture
var tile_rows := 0
var version := 0  ## counts the atlases published
var tiles: Dictionary = {}  ## client row -> its tile in this atlas (the simulation's own row for the dish when the atlas was written: ViewRenderer.thumbnail_region)
