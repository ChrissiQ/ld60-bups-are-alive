class_name EncyclopediaPanel
extends PanelPage
## The encyclopedia (see Encyclopedia): a list of terms on the left, grouped under headings and searchable, and the article of the chosen one on the right, whose
## links go to other entries. Shown by the title screen and by the pause menu in place of what is behind it (each shows that again on `back_requested`);
## `show_entry` opens it on an entry, which is how a click on a band of the genome map gets here. The words are in text/strings.cfg, [encyclopedia].

@onready var search_field: LineEdit = $Box/Columns/Index/Search
@onready var list: VBoxContainer = $Box/Columns/Index/Scroll/List
@onready var none_found: Label = $Box/Columns/Index/NoneFound
@onready var article_scroll: ScrollContainer = $Box/Columns/ArticleScroll
@onready var title_label: Label = $Box/Columns/ArticleScroll/Page/Title
@onready var about_heading: Label = $Box/Columns/ArticleScroll/Page/AboutHeading
@onready var about_body: RichTextLabel = $Box/Columns/ArticleScroll/Page/AboutBody  ## what the thing is in real life
@onready var game_heading: Label = $Box/Columns/ArticleScroll/Page/GameHeading
@onready var game_body: RichTextLabel = $Box/Columns/ArticleScroll/Page/GameBody  ## how it works in the game

var _buttons := {}  ## entry id -> its button in the list
var _headings := {}  ## heading id -> its label in the list
var _group := ButtonGroup.new()
var current := ""  ## the entry whose article is showing


const WIDTH_SHARE := 0.6  ## how much of the window's width the panel takes at the usual interface size, and ...
const HEIGHT_SHARE := 0.8  ## ... of its height; both grow with the interface size (text that is bigger needs the room)
const WIDTH_GROWTH := 0.27  ## by this much of the window for each whole 100% of interface size above the usual, up to all of it
const HEIGHT_GROWTH := 0.2


func _ready() -> void:
	visibility_changed.connect(_fit)
	visibility_changed.connect(_on_visibility_changed)
	get_viewport().size_changed.connect(_fit)
	_fit()
	for category: Array in Encyclopedia.CATEGORIES:
		var heading := Label.new()
		heading.text = Encyclopedia.category_title(category[0])
		heading.theme_type_variation = &"Accent"
		list.add_child(heading)
		_headings[category[0]] = heading
		for id: String in category[1]:
			var button := Button.new()
			button.text = Encyclopedia.title(id)
			button.theme_type_variation = &"CompactListButton"
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.toggle_mode = true
			button.button_group = _group
			button.pressed.connect(show_entry.bind(id))
			list.add_child(button)
			_buttons[id] = button
	search_field.placeholder_text = Strings.t("encyclopedia.search")
	search_field.clear_button_enabled = true
	search_field.text_changed.connect(_filter)
	none_found.text = Strings.t("encyclopedia.none_found")
	for body: RichTextLabel in [about_body, game_body]:
		body.meta_clicked.connect(func(meta: Variant) -> void: show_entry(str(meta)))
	about_heading.text = Strings.t("encyclopedia.heading_about")
	game_heading.text = Strings.t("encyclopedia.heading_game")
	show_entry(Encyclopedia.listed_entries()[0])


## The index is made again each time the panel opens: what the game has decides which entries it lists.
func _on_visibility_changed() -> void:
	if visible:
		_filter(search_field.text)


## The panel's size: a part of the window that grows with the interface size setting (an article at the usual size needs little room, and one in large text more).
func _fit() -> void:
	var steps := maxf(UserSettings.ui_scale - 1.0, 0.0)
	var width := clampf(WIDTH_SHARE + WIDTH_GROWTH * steps, WIDTH_SHARE, 1.0)
	var height := clampf(HEIGHT_SHARE + HEIGHT_GROWTH * steps, HEIGHT_SHARE, 1.0)
	anchor_left = (1.0 - width) * 0.5
	anchor_right = 1.0 - anchor_left
	anchor_top = (1.0 - height) * 0.5
	anchor_bottom = 1.0 - anchor_top
	offset_left = 0.0
	offset_right = 0.0
	offset_top = 0.0
	offset_bottom = 0.0


## Opens the article of an entry (the search is cleared if it would hide the entry).
func show_entry(id: String) -> void:
	if not _buttons.has(id):
		return
	if search_field.text != "" and not Encyclopedia.search(search_field.text).has(id):
		search_field.text = ""
		_filter("")
	if _buttons.has(current):
		(_buttons[current] as Button).set_pressed_no_signal(false)  # (a button group does not unpress the old one when this is silent)
	current = id
	(_buttons[id] as Button).set_pressed_no_signal(true)
	title_label.text = Encyclopedia.title(id)
	var about := Encyclopedia.about(id)
	var game := Encyclopedia.game(id)
	about_body.text = about
	game_body.text = game
	about_body.visible = about != ""
	game_body.visible = game != ""
	about_heading.visible = about != "" and game != ""  # (the two parts are named where there are two to tell apart)
	game_heading.visible = about != "" and game != ""
	article_scroll.scroll_vertical = 0


## Lists only the entries that match the search.
func _filter(query: String) -> void:
	var found := Encyclopedia.search(query)
	for category: Array in Encyclopedia.CATEGORIES:
		var any := false
		for id: String in category[1]:
			(_buttons[id] as Button).visible = found.has(id)
			any = any or found.has(id)
		(_headings[category[0]] as Label).visible = any
	none_found.visible = found.is_empty()

