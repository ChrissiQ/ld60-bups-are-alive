#!/usr/bin/env python3
"""Writes scenes/menu_theme.tres from the design tokens below. Run it from the project root: python3 tools/gen_theme.py

The theme is generated: edit the tokens (colours, radii, spacing, type sizes) or a variation here, run it, and
commit both files; never edit the .tres by hand. A new Theme type variation goes in the "T(...)" list near the end,
with its styles built by flat(...) / empty(...) above it. Then run `godot --headless --path . --import`.
"""
# Generates scenes/menu_theme.tres from design tokens.
def C(r,g,b,a=1.0): return "Color(%g, %g, %g, %g)"%(r,g,b,a)
def rgba(t,a=None): return C(t[0],t[1],t[2],t[3] if a is None else a)

# ---- type: the weight each role of IBM Plex Sans is set in (Commit Mono is for numbers: see StatValue, Unit, the graph and the readouts)
import os
# Light (300) for long text and big type (descriptions, titles); regular (400) for buttons, labels and everything you act on. Medium (500) is
# not for ordinary use: it is kept for the one thing that must stand out in a sentence, the warning. Bold (700) is for the game's name on the title screen only.
LIGHT,REG,EMPH,BOLD="p300","p400","p500","p700"
# ---- tokens
SURFACE=(0.082,0.098,0.108,0.94)    # panels
SURFACE_SOLID=(0.095,0.112,0.122,1.0)
RAISED=(0.145,0.168,0.18,1.0)       # buttons, fields, segments
SUNKEN=(0.055,0.066,0.073,1.0)      # inputs, tracks
HOVER=(0.20,0.23,0.245,1.0)
HAIR=(1,1,1,0.09)                   # hairline
TEXT=(0.93,0.95,0.94,1.0)
MUTED=(0.63,0.69,0.68,1.0)
FAINT=(0.42,0.47,0.46,1.0)
ACCENT=(0.38,0.86,0.64,1.0)
ACCENT_HI=(0.52,0.93,0.74,1.0)
ACCENT_DIM=(0.38,0.86,0.64,0.16)
ON_ACCENT=(0.04,0.13,0.09,1.0)
WARM=(1.0,0.76,0.32,1.0)
DANGER=(0.96,0.40,0.36,1.0)
WARNING=(0.98,0.56,0.42,1.0)  # warnings: a coral of their own, apart from the amber of goals and names and the red of danger
SCRIM=(0.0,0.01,0.015,0.6)
R_PANEL=10; R_CTRL=6
# spacing scale 4 / 8 / 12 / 16 / 24 ; control height 32 (HUD) / 40 (menus)

out=[]
subs=[]
def flat(i,bg,m=(0,0,0,0),r=R_CTRL,bw=0,bc=None,center=True,expand=0,bw_sides=None):
    L=['[sub_resource type="StyleBoxFlat" id="%s"]'%i]
    for k,v in zip(("left","top","right","bottom"),m):
        if v: L.append("content_margin_%s = %g"%(k,v))
    if not center: L.append("draw_center = false")
    L.append("bg_color = "+rgba(bg))
    if bw:
        sides=bw_sides or (bw,bw,bw,bw)
        for k,v in zip(("left","top","right","bottom"),sides):
            if v: L.append("border_width_%s = %d"%(k,v))
        L.append("border_color = "+rgba(bc))
    for k in ("top_left","top_right","bottom_right","bottom_left"): L.append("corner_radius_%s = %d"%(k,r))
    if expand:
        for k,v in zip(("left","top","right","bottom"),expand if isinstance(expand,tuple) else (expand,)*4):
            if v: L.append("expand_margin_%s = %g"%(k,v))
    L.append("")
    subs.append("\n".join(L))
def empty(i,m=(0,0,0,0)):
    L=['[sub_resource type="StyleBoxEmpty" id="%s"]'%i]
    for k,v in zip(("left","top","right","bottom"),m):
        if v: L.append("content_margin_%s = %g"%(k,v))
    L.append(""); subs.append("\n".join(L))

# panels
flat("panel",SURFACE,(16,16,16,16),R_PANEL,1,HAIR)
flat("hud_panel",SURFACE,(14,12,14,12),R_PANEL,1,HAIR)         # cards in the side column
flat("compact_panel",SURFACE,(12,8,12,8),R_PANEL,1,HAIR)
flat("deceased_panel",(0.09,0.09,0.09,0.94),(14,12,14,12),R_PANEL,1,(1,1,1,0.07))
flat("topbar_panel",SURFACE,(12,6,12,6),R_PANEL,1,HAIR)
flat("rail_panel",SURFACE,(6,8,6,8),R_PANEL,1,HAIR)
flat("tray_panel",SURFACE,(12,6,12,6),R_PANEL,1,HAIR)
flat("goal_card",(0.11,0.095,0.06,0.94),(14,12,14,12),R_PANEL,1,(1.0,0.76,0.32,0.45))
flat("popup_panel",SURFACE_SOLID,(8,8,8,8),R_PANEL,1,(1,1,1,0.14))
flat("tooltip_panel",(0.16,0.18,0.19,0.98),(10,6,10,6),R_CTRL,1,(1,1,1,0.14))
flat("dialog_panel",SURFACE_SOLID,(24,56,24,24),12,1,(1,1,1,0.14))
empty("embedded_border",(0,0,0,0))
empty("embedded_unfocused_border",(0,0,0,0))
flat("tutorial_card",SURFACE_SOLID,(20,16,20,16),R_PANEL,1,(1.0,0.76,0.32,0.8))
flat("tutorial_scrim",(0,0.01,0.015,0.7))
flat("tutorial_spot",(0,0,0,0),(),R_PANEL,3,WARM,center=False)
flat("scrim_style",SCRIM)
flat("veil_style",(0.04,0.05,0.055,0.92))
flat("ring_style",(0,0,0,0),(),0,3,(WARM[0],WARM[1],WARM[2],0.4),center=False)
flat("segments",SUNKEN,(3,3,3,3),R_CTRL+2,1,HAIR)
flat("segments_focused",SUNKEN,(3,3,3,3),R_CTRL+2,2,TEXT)
# buttons: 40 px menu buttons, 32 px compact
flat("btn_normal",RAISED,(16,9,16,9),R_CTRL)
flat("btn_hover",HOVER,(16,9,16,9),R_CTRL)
flat("btn_pressed",ACCENT_DIM,(16,9,16,9),R_CTRL,1,(ACCENT[0],ACCENT[1],ACCENT[2],0.6))
flat("btn_disabled",(0.11,0.125,0.135,0.8),(16,9,16,9),R_CTRL)
flat("btn_focus",(0,0,0,0),(),R_CTRL,2,TEXT,center=False)
flat("dialog_btn_normal",RAISED,(20,10,20,10),R_CTRL)
flat("dialog_btn_hover",HOVER,(20,10,20,10),R_CTRL)
flat("dialog_btn_pressed",ACCENT_DIM,(20,10,20,10),R_CTRL,1,(ACCENT[0],ACCENT[1],ACCENT[2],0.6))
flat("dialog_btn_focus",(0,0,0,0),(),R_CTRL,2,TEXT,center=False)
flat("primary_normal",ACCENT,(18,9,18,9),R_CTRL)
flat("primary_hover",ACCENT_HI,(18,9,18,9),R_CTRL)
flat("primary_pressed",(0.30,0.72,0.52,1),(18,9,18,9),R_CTRL)
flat("primary_disabled",(ACCENT[0],ACCENT[1],ACCENT[2],0.14),(18,9,18,9),R_CTRL)
flat("primary_focus",(0,0,0,0),(),R_CTRL,2,TEXT,center=False)
flat("dprimary_normal",ACCENT,(20,10,20,10),R_CTRL)
flat("dprimary_hover",ACCENT_HI,(20,10,20,10),R_CTRL)
flat("dprimary_pressed",(0.30,0.72,0.52,1),(20,10,20,10),R_CTRL)
flat("danger_normal",(DANGER[0],DANGER[1],DANGER[2],0.08),(20,10,20,10),R_CTRL,1,(DANGER[0],DANGER[1],DANGER[2],0.8))
flat("danger_hover",(DANGER[0],DANGER[1],DANGER[2],0.9),(20,10,20,10),R_CTRL)
flat("danger_pressed",(0.82,0.32,0.30,1),(20,10,20,10),R_CTRL)
# icon + tool buttons (square, 36)
flat("icon_normal",(0,0,0,0),(6,6,6,6),R_CTRL)
flat("icon_hover",HOVER,(6,6,6,6),R_CTRL)
flat("icon_pressed",ACCENT_DIM,(6,6,6,6),R_CTRL)
flat("tool_armed",(0,0,0,0),(6,6,6,6),R_CTRL,1,(ACCENT[0],ACCENT[1],ACCENT[2],0.7))
flat("tool_normal",(0,0,0,0),(6,6,6,6),R_CTRL)
flat("tool_hover",HOVER,(6,6,6,6),R_CTRL)
flat("tool_pressed",ACCENT,(6,6,6,6),R_CTRL)
flat("tool_hover_pressed",ACCENT_HI,(6,6,6,6),R_CTRL)
flat("tool_disabled",(0,0,0,0),(6,6,6,6),R_CTRL)
flat("switch_pressed",ACCENT_DIM,(6,6,6,6),R_CTRL)
flat("switch_hover_pressed",(ACCENT[0],ACCENT[1],ACCENT[2],0.28),(6,6,6,6),R_CTRL)
flat("tab_normal",(0,0,0,0),(16,9,16,9),R_CTRL)
flat("tab_hover",(1,1,1,0.07),(16,9,16,9),R_CTRL)
flat("tab_pressed",ACCENT,(16,9,16,9),R_CTRL)
flat("tab_hover_pressed",ACCENT_HI,(16,9,16,9),R_CTRL)
flat("section_normal",(0,0,0,0),(0,4,0,4),R_CTRL)
flat("section_hover",(1,1,1,0.05),(0,4,0,4),R_CTRL,expand=(8,0,8,0))  # (the highlight reaches past the text and chevron, which stay where they are)
# segmented choices
flat("check_focus",(0,0,0,0),(0,4,0,4),R_CTRL,2,TEXT,center=False)
# a dropdown that is a quiet outlined field (the graph's trait choice)
flat("select_normal",(0,0,0,0),(8,2,6,2),R_CTRL,1,HAIR)
flat("select_hover",(1,1,1,0.07),(8,2,6,2),R_CTRL,1,(1,1,1,0.25))
flat("popup_item_hover",(1,1,1,0.09),(6,3,6,3),R_CTRL)
flat("notice_panel",RAISED,(14,8,14,8),R_CTRL,1,(1,1,1,0.16))
flat("sw_normal",(0,0,0,0),(10,1,10,1),R_CTRL)
flat("sw_hover",(1,1,1,0.07),(10,1,10,1),R_CTRL)
flat("sw_pressed",ACCENT,(10,1,10,1),R_CTRL)
flat("sw_hover_pressed",ACCENT_HI,(10,1,10,1),R_CTRL)
flat("sw_segments",SUNKEN,(2,2,2,2),R_CTRL+2,1,HAIR)
flat("sw_segments_focused",SUNKEN,(2,2,2,2),R_CTRL+2,2,TEXT)
flat("choice_normal",(0,0,0,0),(12,4,12,4),R_CTRL)
flat("choice_hover",(1,1,1,0.07),(12,4,12,4),R_CTRL)
flat("choice_pressed",ACCENT,(12,4,12,4),R_CTRL)
flat("choice_hover_pressed",ACCENT_HI,(12,4,12,4),R_CTRL)
flat("choice_disabled",(0,0,0,0),(12,4,12,4),R_CTRL)
empty("bare_empty")
empty("check_empty",(0,4,0,4))
# step badges
flat("badge_plain",RAISED,(0,0,0,0),13)
flat("badge_current",ACCENT,(0,0,0,0),13)
flat("badge_done",ACCENT_DIM,(0,0,0,0),13)
flat("warn_icon",(0,0,0,0),(0,0,0,0),0)
# list rows
flat("list_normal",(0,0,0,0),(8,3,8,3),R_CTRL)
flat("list_hover",HOVER,(8,3,8,3),R_CTRL)
flat("list_pressed",ACCENT_DIM,(8,3,8,3),R_CTRL)
# fields
flat("edit_normal",SUNKEN,(8,5,8,5),R_CTRL,1,(1,1,1,0.12))
flat("edit_focus",SUNKEN,(8,5,8,5),R_CTRL,2,ACCENT)
flat("edit_tight",SUNKEN,(6,2,6,2),R_CTRL,1,(1,1,1,0.12))
flat("edit_tight_focus",SUNKEN,(6,2,6,2),R_CTRL,2,ACCENT)
empty("bup_name_field",(3,0,3,0))
empty("dialog_text_pad",(0,0,0,12))
# sliders / scroll / progress
flat("graph_pill",(0,0,0,0),(8,2,8,2),R_CTRL,1,(1,1,1,0.18))
flat("graph_pill_hover",(1,1,1,0.08),(8,2,8,2),R_CTRL,1,(1,1,1,0.32))
flat("slider_focus",(0,0,0,0),(0,0,0,0),R_CTRL,2,ACCENT,center=False)
flat("slider_track",SUNKEN,(0,3,0,3),3,1,(1,1,1,0.10))
flat("slider_fill",(ACCENT[0],ACCENT[1],ACCENT[2],0.85),(0,3,0,3),3)
flat("slider_fill_hi",ACCENT,(0,3,0,3),3)
flat("scroll_track",(1,1,1,0.05),(5,0,5,0),5)
flat("scroll_grabber",(1,1,1,0.32),(5,0,5,0),5)
flat("scroll_grabber_hi",(1,1,1,0.6),(5,0,5,0),5)
flat("goal_bar_bg",SUNKEN,(0,4,0,4),4)
flat("goal_bar_fill",WARM,(0,0,0,0),4)

subs.append('''[sub_resource type="StyleBoxLine" id="sep_v"]
color = Color(1, 1, 1, 0.12)
vertical = true
thickness = 1

[sub_resource type="StyleBoxLine" id="sep_h"]
color = Color(1, 1, 1, 0.12)
thickness = 1
''')
ext='''[gd_resource type="Theme" format=3 uid="uid://i3jbu01lnbni"]

[ext_resource type="Texture2D" path="res://icons/check_on.svg" id="check_on"]
[ext_resource type="Texture2D" path="res://icons/chevron_small.svg" id="chevron_small"]
[ext_resource type="Texture2D" path="res://icons/check_off.svg" id="check_off"]
[ext_resource type="FontFile" uid="uid://dvk0wfx7w138g" path="res://fonts/CommitMono-500.otf" id="m500"]
[ext_resource type="FontFile" uid="uid://dorcirpa3je5u" path="res://fonts/CommitMono-700.otf" id="m700"]
[ext_resource type="FontFile" path="res://fonts/IBMPlexSans-300.ttf" id="p300"]
[ext_resource type="FontFile" path="res://fonts/IBMPlexSans-400.ttf" id="p400"]
[ext_resource type="FontFile" path="res://fonts/IBMPlexSans-500.ttf" id="p500"]
[ext_resource type="FontFile" path="res://fonts/IBMPlexSans-700.ttf" id="p700"]

[sub_resource type="PlaceholderTexture2D" id="no_icon"]
size = Vector2(1, 1)

'''
res=[]
def T(name,base=None,colors={},sizes={},fonts={},consts={},styles={},icons={}):
    if base: res.append('%s/base_type = &"%s"'%(name,base))
    for k,v in sorted(colors.items()): res.append("%s/colors/%s = %s"%(name,k,v if isinstance(v,str) else rgba(v)))
    for k,v in sorted(consts.items()): res.append("%s/constants/%s = %s"%(name,k,v))
    for k,v in sorted(sizes.items()): res.append("%s/font_sizes/%s = %d"%(name,k,v))
    for k,v in sorted(fonts.items()): res.append('%s/fonts/%s = ExtResource("%s")'%(name,k,v))
    for k,v in sorted(icons.items()): res.append('%s/icons/%s = %s'%(name,k,v))
    for k,v in sorted(styles.items()): res.append('%s/styles/%s = SubResource("%s")'%(name,k,v))
S=lambda i:i
OUTLINE=(0,0,0,0.85)

res.append('default_font = ExtResource("%s")'%REG)
res.append('default_font_size = 15')
# --- roles (type scale: 12 caption, 14 note/field, 15 body, 18 title, 22 heading, 56 display)
T("Label",colors={"font_color":TEXT})
T("Bright","Label",colors={"font_color":TEXT},fonts={"font":REG})
T("BrightFlash","Label",colors={"font_color":ACCENT_HI},fonts={"font":REG})  # the first number of a readout while it has just changed (see UiText.numbers)
T("CardTitle","Label",colors={"font_color":WARM},sizes={"font_size":20},fonts={"font":LIGHT})
T("CardText","Label",colors={"font_color":TEXT},sizes={"font_size":15},fonts={"font":LIGHT},consts={"line_spacing":3})
T("FocusLabel","Label",colors={"font_color":ACCENT})
T("Hint","Label",colors={"font_color":MUTED},sizes={"font_size":13},fonts={"font":LIGHT})
T("Note","Label",colors={"font_color":MUTED},sizes={"font_size":13},fonts={"font":LIGHT})
T("Unit","Label",colors={"font_color":FAINT},sizes={"font_size":13},fonts={"font":"m500"})
T("StatValue","Label",colors={"font_color":TEXT},sizes={"font_size":13},fonts={"font":"m500"})
T("Warning","Label",colors={"font_color":(1.0,0.78,0.70,1.0)},sizes={"font_size":14},fonts={"font":EMPH})
T("WarningIcon","Button",colors={k:WARNING for k in ("icon_normal_color","icon_disabled_color","icon_hover_color","icon_pressed_color","icon_focus_color","icon_hover_pressed_color")},consts={"icon_max_width":24},styles={k:"warn_icon" for k in ("normal","disabled","hover","pressed","hover_pressed","focus")})
T("Small","Label",colors={"font_color":MUTED},sizes={"font_size":13},fonts={"font":LIGHT})
T("SmallBright","Label",colors={"font_color":TEXT},sizes={"font_size":13},fonts={"font":REG})
T("ReadoutLabel","Label",sizes={"font_size":13})
T("Accent","Label",colors={"font_color":WARM},fonts={"font":REG})
T("Heading","Label",colors={"font_color":TEXT},sizes={"font_size":22},fonts={"font":LIGHT})
T("Title","Label",colors={"font_color":TEXT},sizes={"font_size":44},fonts={"font":LIGHT})
T("Display","Label",colors={"font_color":TEXT},sizes={"font_size":72},fonts={"font":BOLD})
T("Tagline","Label",colors={"font_color":WARM},sizes={"font_size":20},fonts={"font":LIGHT})
T("Story","Label",colors={"font_color":TEXT},sizes={"font_size":18},consts={"line_spacing":5},fonts={"font":LIGHT})
T("Notice","Label",colors={"font_color":TEXT},sizes={"font_size":14},fonts={"font":REG},styles={"normal":"notice_panel"})
T("Banner","Label",colors={"font_color":TEXT,"font_outline_color":OUTLINE},consts={"outline_size":6},sizes={"font_size":26},fonts={"font":LIGHT})
T("BupName","Label",colors={"font_color":WARM},sizes={"font_size":16},fonts={"font":REG})
T("BupNameField","LineEdit",colors={"caret_color":WARM,"font_color":WARM},sizes={"font_size":16},fonts={"font":REG},styles={"focus":"bup_name_field","normal":"bup_name_field"})
T("DialogTitle","Label",colors={"font_color":TEXT},sizes={"font_size":20},fonts={"font":LIGHT})
T("DialogText","Label",sizes={"font_size":16},styles={"normal":"dialog_text_pad"},fonts={"font":LIGHT})
T("TooltipLabel",colors={"font_color":TEXT},sizes={"font_size":13})
# rich text
T("RichTextLabel",fonts={"bold_font":REG,"mono_font":"m500","normal_font":REG})
T("Readout","RichTextLabel",colors={"default_color":TEXT},fonts={"normal_font":"m500","bold_font":"m700"},sizes={"bold_font_size":14,"mono_font_size":14,"normal_font_size":14})
T("Article","RichTextLabel",colors={"default_color":TEXT},fonts={"normal_font":LIGHT,"bold_font":REG,"mono_font":"m500"},sizes={"bold_font_size":15,"mono_font_size":14,"normal_font_size":15})
T("ReadoutMuted","RichTextLabel",colors={"default_color":MUTED},fonts={"normal_font":REG,"bold_font":REG},sizes={"bold_font_size":14,"mono_font_size":14,"normal_font_size":14})
T("ReadoutAccent","RichTextLabel",colors={"default_color":WARM},fonts={"normal_font":LIGHT,"bold_font":REG},sizes={"bold_font_size":14,"mono_font_size":14,"normal_font_size":14})
T("StoryHeading","RichTextLabel",colors={"default_color":WARM},fonts={"normal_font":LIGHT,"bold_font":REG},sizes={"bold_font_size":18,"mono_font_size":18,"normal_font_size":18})
# panels
T("PanelContainer",styles={"panel":"panel"})
T("CompactPanel","PanelContainer",styles={"panel":"compact_panel"})
T("HudPanel","PanelContainer",styles={"panel":"hud_panel"})
T("DeceasedPanel","PanelContainer",styles={"panel":"deceased_panel"})
T("Bare","PanelContainer",styles={"panel":"bare_empty"})
T("TopBar","PanelContainer",styles={"panel":"topbar_panel"})
T("Rail","PanelContainer",styles={"panel":"rail_panel"})
T("Tray","PanelContainer",styles={"panel":"tray_panel"})
T("GoalCard","PanelContainer",styles={"panel":"goal_card"})
T("GoalBar","ProgressBar",styles={"background":"goal_bar_bg","fill":"goal_bar_fill"})
T("TutorialCard","PanelContainer",styles={"panel":"tutorial_card"})
T("TutorialScrim","Panel",styles={"panel":"tutorial_scrim"})
T("TutorialSpot","Panel",styles={"panel":"tutorial_spot"})
T("Scrim","Panel",styles={"panel":"scrim_style"})
T("Veil","Panel",styles={"panel":"veil_style"})
T("RingPanel","Panel",styles={"panel":"ring_style"})
T("Segments","PanelContainer",styles={"panel":"segments"})
T("SwitchSegments","PanelContainer",styles={"panel":"sw_segments"})
T("SwitchSegmentsFocused","PanelContainer",styles={"panel":"sw_segments_focused"})
T("SegmentsFocused","PanelContainer",styles={"panel":"segments_focused"})
T("PopupPanel",styles={"panel":"popup_panel"})
T("TooltipPanel",styles={"panel":"tooltip_panel"})
# stacks: spacing scale 4 / 8 / 16 / 24
T("FlushStack","VBoxContainer",consts={"separation":0})
T("SnugStack","VBoxContainer",consts={"separation":4})
T("TightStack","VBoxContainer",consts={"separation":8})
T("RoomyStack","VBoxContainer",consts={"separation":16})
T("SectionStack","VBoxContainer",consts={"separation":28})
T("SpaciousStack","VBoxContainer",consts={"separation":24})
T("Frame","MarginContainer",consts={"margin_left":12,"margin_top":12,"margin_right":12,"margin_bottom":12})
T("SpaciousRow","HBoxContainer",consts={"separation":32})
T("TightGroup","HBoxContainer",consts={"separation":8})
T("HSeparator",consts={"separation":9},styles={"separator":"sep_h"})
T("VSeparator",consts={"separation":9},styles={"separator":"sep_v"})
T("TightRow","HBoxContainer",consts={"separation":4})
T("SegmentRow","HBoxContainer",consts={"separation":2})
T("TightFlow","HFlowContainer",consts={"h_separation":4,"v_separation":4})
T("HBoxContainer",consts={"separation":12})
T("VBoxContainer",consts={"separation":12})
T("GridContainer",consts={"h_separation":24,"v_separation":6})
T("ScrollContainer",consts={"scrollbar_h_separation":8})
# buttons
T("Button",colors={"font_color":TEXT,"font_disabled_color":FAINT,"font_focus_color":TEXT,"font_hover_color":TEXT,"font_hover_pressed_color":ACCENT_HI,"font_pressed_color":ACCENT,
 "icon_disabled_color":FAINT,"icon_focus_color":TEXT,"icon_hover_color":TEXT,"icon_hover_pressed_color":ACCENT_HI,"icon_normal_color":TEXT,"icon_pressed_color":ACCENT},
 sizes={"font_size":15},fonts={"font":REG},styles={"disabled":"btn_disabled","focus":"btn_focus","hover":"btn_hover","hover_pressed":"btn_pressed","normal":"btn_normal","pressed":"btn_pressed"})
T("PrimaryButton","Button",colors={k:ON_ACCENT for k in("font_color","font_focus_color","font_hover_color","font_hover_pressed_color","font_pressed_color")},
 styles={"focus":"primary_focus","hover":"primary_hover","hover_pressed":"primary_pressed","normal":"primary_normal","pressed":"primary_pressed","disabled":"primary_disabled"})
T("SmallButton","Button",sizes={"font_size":14},consts={"icon_max_width":16,"h_separation":6})
T("PictureButton","Button",colors={**{k:(1,1,1,1) for k in ("icon_normal_color","icon_hover_color","icon_pressed_color","icon_hover_pressed_color","icon_focus_color","icon_disabled_color")}},sizes={"font_size":14},consts={"icon_max_width":24,"h_separation":8})
T("SmallPrimaryButton","Button",colors={**{k:ON_ACCENT for k in("font_color","font_focus_color","font_hover_color","font_hover_pressed_color","font_pressed_color")},"font_disabled_color":(ACCENT[0],ACCENT[1],ACCENT[2],0.5)},
 sizes={"font_size":14},styles={"focus":"primary_focus","hover":"primary_hover","hover_pressed":"primary_pressed","normal":"primary_normal","pressed":"primary_pressed","disabled":"primary_disabled"})
T("DialogButton","Button",sizes={"font_size":15},styles={"focus":"dialog_btn_focus","hover":"dialog_btn_hover","hover_pressed":"dialog_btn_pressed","normal":"dialog_btn_normal","pressed":"dialog_btn_pressed"})
T("DialogPrimaryButton","Button",colors={k:ON_ACCENT for k in ("font_color","font_focus_color","font_hover_color","font_hover_pressed_color","font_pressed_color")},sizes={"font_size":15},styles={"focus":"primary_focus","hover":"dprimary_hover","hover_pressed":"dprimary_pressed","normal":"dprimary_normal","pressed":"dprimary_pressed"})
T("DialogDangerButton","Button",colors={"font_color":(1.0,0.62,0.58,1),"font_focus_color":(1.0,0.62,0.58,1),"font_hover_color":(0.2,0.04,0.04,1),"font_hover_pressed_color":(0.2,0.04,0.04,1),"font_pressed_color":(0.2,0.04,0.04,1)},sizes={"font_size":15},styles={"focus":"dialog_btn_focus","hover":"danger_hover","hover_pressed":"danger_pressed","normal":"danger_normal","pressed":"danger_pressed"})
T("IconButton","Button",colors={"icon_focus_color":TEXT,"icon_hover_color":TEXT,"icon_hover_pressed_color":ACCENT_HI,"icon_normal_color":MUTED,"icon_pressed_color":ACCENT},consts={"icon_max_width":18},styles={"hover":"icon_hover","hover_pressed":"icon_pressed","normal":"icon_normal","pressed":"icon_pressed"})
T("ToolButton","Button",colors={"icon_disabled_color":(1,1,1,0.22),"icon_normal_color":MUTED,"icon_hover_color":TEXT,"icon_focus_color":MUTED,"icon_pressed_color":ON_ACCENT,"icon_hover_pressed_color":ON_ACCENT},consts={"icon_max_width":20},styles={"disabled":"tool_disabled","hover":"tool_hover","hover_pressed":"tool_hover_pressed","normal":"tool_normal","pressed":"tool_pressed"})
T("ToolButtonArmed","Button",colors={"icon_disabled_color":(1,1,1,0.22),"icon_normal_color":ACCENT,"icon_hover_color":ACCENT_HI,"icon_focus_color":ACCENT,"icon_pressed_color":ON_ACCENT,"icon_hover_pressed_color":ON_ACCENT},consts={"icon_max_width":20},styles={"disabled":"tool_disabled","hover":"tool_hover","hover_pressed":"tool_hover_pressed","normal":"tool_armed","pressed":"tool_pressed"})
T("ToggleButton","Button",colors={"icon_disabled_color":(1,1,1,0.22),"icon_normal_color":FAINT,"icon_hover_color":MUTED,"icon_focus_color":FAINT,"icon_pressed_color":ACCENT,"icon_hover_pressed_color":ACCENT_HI},consts={"icon_max_width":20},styles={"disabled":"tool_disabled","hover":"tool_hover","hover_pressed":"switch_hover_pressed","normal":"tool_normal","pressed":"switch_pressed"})
T("TabButton","Button",colors={"font_color":MUTED,"font_hover_color":TEXT,"font_pressed_color":ON_ACCENT,"font_hover_pressed_color":ON_ACCENT,"font_focus_color":MUTED},sizes={"font_size":15},styles={"disabled":"tab_normal","hover":"tab_hover","hover_pressed":"tab_hover_pressed","normal":"tab_normal","pressed":"tab_pressed"})
T("SectionButton","Button",colors={"font_color":TEXT,"font_hover_color":TEXT,"font_pressed_color":TEXT,"font_hover_pressed_color":TEXT,"font_focus_color":TEXT,"icon_normal_color":MUTED,"icon_hover_color":TEXT,"icon_pressed_color":MUTED,"icon_hover_pressed_color":TEXT,"icon_focus_color":MUTED},consts={"icon_max_width":16,"h_separation":6},sizes={"font_size":13},fonts={"font":REG},styles={"disabled":"section_normal","hover":"section_hover","hover_pressed":"section_hover","normal":"section_normal","pressed":"section_normal","focus":"section_normal"})
T("TraitSelect","OptionButton",colors={"font_color":ACCENT,"font_hover_color":ACCENT_HI,"font_pressed_color":ACCENT_HI,"font_hover_pressed_color":ACCENT_HI,"font_focus_color":ACCENT},sizes={"font_size":13},fonts={"font":REG},consts={"arrow_margin":6,"h_separation":6},icons={"arrow":'ExtResource("chevron_small")'},styles={"disabled":"select_normal","focus":"btn_focus","hover":"select_hover","hover_pressed":"select_hover","normal":"select_normal","pressed":"select_hover"})
T("PopupMenu",colors={"font_color":MUTED,"font_hover_color":TEXT,"font_focus_color":TEXT,"font_accelerator_color":FAINT},sizes={"font_size":13},fonts={"font":REG},consts={"v_separation":2,"h_separation":8,"item_start_padding":6,"item_end_padding":6},styles={"panel":"popup_panel","hover":"popup_item_hover","focus":"popup_item_hover"})
T("SwitchButton","Button",colors={"font_color":MUTED,"font_hover_color":TEXT,"font_pressed_color":ON_ACCENT,"font_hover_pressed_color":ON_ACCENT,"font_focus_color":MUTED},sizes={"font_size":13},styles={"disabled":"sw_normal","hover":"sw_hover","hover_pressed":"sw_hover_pressed","normal":"sw_normal","pressed":"sw_pressed"})
T("ChoiceButton","Button",colors={**{k:(1,1,1,1) for k in ("icon_normal_color","icon_hover_color","icon_pressed_color","icon_hover_pressed_color","icon_focus_color","icon_disabled_color")},"font_color":MUTED,"font_hover_color":TEXT,"font_pressed_color":ON_ACCENT,"font_hover_pressed_color":ON_ACCENT,"font_focus_color":MUTED},sizes={"font_size":14},consts={"icon_max_width":22,"h_separation":6},styles={"disabled":"choice_disabled","hover":"choice_hover","hover_pressed":"choice_hover_pressed","normal":"choice_normal","pressed":"choice_pressed"})
T("Badge","PanelContainer",styles={"panel":"badge_plain"})
T("BadgeCurrent","PanelContainer",styles={"panel":"badge_current"})
T("BadgeDone","PanelContainer",styles={"panel":"badge_done"})
T("BadgeNumber","Label",colors={"font_color":MUTED},sizes={"font_size":13},fonts={"font":REG})
T("BadgeNumberCurrent","Label",colors={"font_color":ON_ACCENT},sizes={"font_size":13},fonts={"font":REG})
T("BadgeNumberDone","Label",colors={"font_color":ACCENT},sizes={"font_size":13},fonts={"font":REG})
T("StepName","Label",colors={"font_color":MUTED},fonts={"font":REG})
T("StepNameCurrent","Label",colors={"font_color":TEXT},fonts={"font":REG})
T("StepNameDone","Label",colors={"font_color":MUTED},fonts={"font":REG})
T("ListButton","Button",colors={"font_disabled_color":WARM},sizes={"font_size":15},styles={"disabled":"icon_normal","hover":"icon_hover","hover_pressed":"icon_pressed","normal":"icon_normal","pressed":"icon_pressed"})
T("CompactListButton","Button",colors={"font_disabled_color":WARM,"font_color":TEXT},sizes={"font_size":13},styles={"disabled":"list_normal","hover":"list_hover","hover_pressed":"list_pressed","normal":"list_normal","pressed":"list_pressed"})
T("DeceasedListButton","Button",colors={"font_color":(0.55,0.58,0.57,1),"font_hover_color":(0.75,0.78,0.77,1),"font_pressed_color":(0.75,0.78,0.77,1),"font_hover_pressed_color":(0.75,0.78,0.77,1)},sizes={"font_size":13},styles={"disabled":"list_normal","hover":"list_hover","hover_pressed":"list_pressed","normal":"list_normal","pressed":"list_pressed"})
T("CheckBox",colors={"font_color":TEXT,"font_hover_color":TEXT,"font_hover_pressed_color":TEXT,"font_pressed_color":TEXT},consts={"h_separation":6},sizes={"font_size":13},
 icons={"checked":'ExtResource("check_on")',"unchecked":'ExtResource("check_off")'},styles={k:"check_empty" for k in("disabled","hover","hover_pressed","normal","pressed")})
# fields
T("LineEdit",colors={"caret_color":ACCENT,"font_color":TEXT,"selection_color":(ACCENT[0],ACCENT[1],ACCENT[2],0.35)},styles={"focus":"edit_focus","normal":"edit_normal"})
T("ReadoutField","LineEdit",consts={"minimum_character_width":1},sizes={"font_size":16},fonts={"font":"m500"},styles={"focus":"edit_tight_focus","normal":"edit_tight"})
T("CompactField","LineEdit",consts={"minimum_character_width":1},sizes={"font_size":16},fonts={"font":"m500"})
T("CompactSpinBox","SpinBox",consts={"buttons_width":12})
T("HSlider",styles={"grabber_area":"slider_fill","grabber_area_highlight":"slider_fill_hi","slider":"slider_track","focus":"slider_focus"})
T("VScrollBar",styles={"scroll":"scroll_track","scroll_focus":"scroll_track","grabber":"scroll_grabber","grabber_highlight":"scroll_grabber_hi","grabber_pressed":"scroll_grabber_hi"})
T("ColorPicker",consts={"h_width":22,"sv_height":170,"sv_width":215})
# dialogs and windows
T("AcceptDialog",consts={"buttons_min_width":96,"buttons_separation":12},sizes={"title_font_size":20},styles={"panel":"dialog_panel"})
T("ConfirmationDialog",consts={"buttons_min_width":96,"buttons_separation":12},sizes={"title_font_size":20},styles={"panel":"dialog_panel"})
T("Window",consts={"close_h_offset":24,"close_v_offset":34,"title_height":60},sizes={"title_font_size":20},styles={"embedded_border":"embedded_border","embedded_unfocused_border":"embedded_unfocused_border"})
# graph
T("GaugeBar",colors={"track":(1,1,1,0.07),"band":(1,1,1,0.13),"tick":(1,1,1,0.9),"fill":ACCENT,"limited":WARM,"starving":DANGER,"dead":FAINT})  # the bars of a bup's panel (ui/gauge_bar.gd)
T("StatLimited","Label",colors={"font_color":WARM},sizes={"font_size":13},fonts={"font":"m500"})  # a bup's reserve word while it is food-limited (ui/bup_gauges.gd)
T("StatStarving","Label",colors={"font_color":DANGER},sizes={"font_size":13},fonts={"font":"m500"})  # ... and while it is starving
T("StatLeader",colors={"line":(1,1,1,0.16)})  # the dotted line between a stat's name and its value (ui/stat_leader.gd)
T("GenomeSlot",colors={"track":(1,1,1,0.07),"symbol":(0.05,0.07,0.08,0.92),"symbol_dim":(1,1,1,0.4)},sizes={"font_size":12},fonts={"font":"m500"})  # the chromosome map's slots (ui/genome_slot.gd)
T("GenomeGrid","GridContainer",consts={"h_separation":10,"v_separation":0})
T("HistoryGraph",styles={"pill":"graph_pill","pill_hover":"graph_pill_hover"},fonts={"font":"m500"},colors={"background":(0.082,0.098,0.108,0.0),"border":(1,1,1,0.0),"grid":(1,1,1,0.07),"grid_faint":(1,1,1,0.04),"muted":MUTED,"population":WARM,"trait":ACCENT},sizes={"legend":13,"tick":12})

open("scenes/menu_theme.tres","w").write(ext+"\n".join(subs)+"\n[resource]\n"+"\n".join(res)+"\n")
