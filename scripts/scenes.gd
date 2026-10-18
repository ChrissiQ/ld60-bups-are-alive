class_name Scenes
extends RefCounted
## Every screen the game can show, in one place. Scripts change screens with these constants
## (`get_tree().change_scene_to_file(Scenes.MENU)`), never with a path of their own.
## tests/ui_lint_test.gd fails if a script spells out a scene path.

const MENU := "res://scenes/menu.tscn"
const INTRO := "res://scenes/intro.tscn"
const FREE_SETUP := "res://scenes/free_setup.tscn"
const FOUNDERS := "res://scenes/founders.tscn"
const GAME := "res://scenes/main.tscn"
