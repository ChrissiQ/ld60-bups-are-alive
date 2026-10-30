#!/usr/bin/env python3
"""Writes scenes/menu_theme.tres from the design tokens below. Run it from the project root: python3 tools/gen_theme.py (--check only compares)

The theme is generated: edit design/tokens.json (or a variation here), run it, and
commit the files; never edit the .tres by hand. Colours, fonts, sizes, radii and spacing are defined in design/tokens.json only. A new Theme type variation goes in the "T(...)" list near the end,
with its styles built by flat(...) / empty(...) above it. Then run `godot --headless --path . --import`.
"""
# Generates scenes/menu_theme.tres from design tokens.
def C(r,g,b,a=1.0): return "Color(%g, %g, %g, %g)"%(r,g,b,a)
def rgba(t,a=None): return C(t[0],t[1],t[2],t[3] if a is None else a)

# ---- tokens: every colour, font, size, radius and spacing value comes from design/tokens.json (see tools/design_tokens.py)
import os, sys
sys.dont_write_bytecode=True
import design_tokens
D=design_tokens.load()
COL=design_tokens.colors(D)
SURFACE,SURFACE_SOLID,RAISED,SUNKEN,HOVER=(COL[k] for k in ("surface","surface_solid","raised","sunken","hover"))
TEXT,MUTED,FAINT=(COL[k] for k in ("text","muted","faint"))
ACCENT,ACCENT_HI,ACCENT_DIM,ACCENT_PRESSED,ON_ACCENT=(COL[k] for k in ("accent","accent_hi","accent_dim","accent_pressed","on_accent"))
EMPHASIS,WARNING,WARNING_TEXT,DANGER,DANGER_PRESSED,DANGER_TEXT,ON_DANGER=(COL[k] for k in ("emphasis","warning","warning_text","danger","danger_pressed","danger_text","on_danger"))
SCRIM,SCRIM_TUTORIAL,VEIL,TOOLTIP_FILL,DECEASED_FILL,GOAL_FILL,DISABLED_FILL=(COL[k] for k in ("scrim","scrim_tutorial","veil","tooltip_fill","deceased_fill","goal_fill","disabled_fill"))
DECEASED_TEXT,DECEASED_TEXT_HI,OUTLINE,ON_BAND=(COL[k] for k in ("deceased_text","deceased_text_hi","outline","on_band"))
HAIR,WHITE,NONE=(COL[k] for k in ("hair","white","none"))
FS={s["name"]:s["px"] for s in D["typography"]["sizes"]}
FONT_WEIGHTS={w["name"]:w for w in D["typography"]["weights"]}
def font_id(w): return ("p" if w["family"]=="text" else "m")+str(w["weight"])
LIGHT,REG,EMPH,BOLD=(font_id(FONT_WEIGHTS[k]) for k in ("light","regular","medium","bold"))
MONO=font_id(FONT_WEIGHTS["mono_medium"]); MONO_BOLD=font_id(FONT_WEIGHTS["mono_bold"])
RADII={r["name"]:r["px"] for r in D["radii"]}
R_PANEL=RADII["panel"]; R_CTRL=RADII["control"]
BORDER={b["name"]:b["px"] for b in D["borders"]}
ICON={i["name"]:i["px"] for i in D["icons"]}
SP={s["name"]:s["px"] for s in D["spacing"]}

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
flat("panel",SURFACE,(16,16,16,16),R_PANEL,BORDER["hairline"],HAIR)
flat("hud_panel",SURFACE,(14,12,14,12),R_PANEL,BORDER["hairline"],HAIR)         # cards in the side column
flat("compact_panel",SURFACE,(12,8,12,8),R_PANEL,BORDER["hairline"],HAIR)
flat("deceased_panel",DECEASED_FILL,(14,12,14,12),R_PANEL,BORDER["hairline"],COL["deceased_border"])
flat("topbar_panel",SURFACE,(12,6,12,6),R_PANEL,BORDER["hairline"],HAIR)
flat("rail_panel",SURFACE,(6,8,6,8),R_PANEL,BORDER["hairline"],HAIR)
flat("tray_panel",SURFACE,(12,6,12,6),R_PANEL,BORDER["hairline"],HAIR)
flat("goal_card",GOAL_FILL,(14,12,14,12),R_PANEL,BORDER["hairline"],(*EMPHASIS[:3],0.45))
flat("popup_panel",SURFACE_SOLID,(8,8,8,8),R_PANEL,BORDER["hairline"],COL["popup_border"])
flat("tooltip_panel",TOOLTIP_FILL,(10,6,10,6),R_CTRL,BORDER["hairline"],COL["popup_border"])
flat("dialog_panel",SURFACE_SOLID,(24,56,24,24),12,BORDER["hairline"],COL["popup_border"])
empty("embedded_border",(0,0,0,0))
empty("embedded_unfocused_border",(0,0,0,0))
flat("tutorial_card",SURFACE_SOLID,(20,16,20,16),R_PANEL,BORDER["hairline"],(*EMPHASIS[:3],0.8))
flat("tutorial_scrim",SCRIM_TUTORIAL)
flat("tutorial_spot",NONE,(),R_PANEL,BORDER["ring"],EMPHASIS,center=False)
flat("scrim_style",SCRIM)
flat("veil_style",VEIL)
flat("ring_style",NONE,(),0,BORDER["ring"],(EMPHASIS[0],EMPHASIS[1],EMPHASIS[2],0.4),center=False)
flat("segments",SUNKEN,(3,3,3,3),R_CTRL+2,BORDER["hairline"],HAIR)
flat("segments_focused",SUNKEN,(3,3,3,3),R_CTRL+2,BORDER["focus"],TEXT)
# buttons: 40 px menu buttons, 32 px compact
flat("btn_normal",RAISED,(16,9,16,9),R_CTRL)
flat("btn_hover",HOVER,(16,9,16,9),R_CTRL)
flat("btn_pressed",ACCENT_DIM,(16,9,16,9),R_CTRL,BORDER["hairline"],(ACCENT[0],ACCENT[1],ACCENT[2],0.6))
flat("btn_disabled",DISABLED_FILL,(16,9,16,9),R_CTRL)
flat("btn_focus",NONE,(),R_CTRL,BORDER["focus"],TEXT,center=False)
flat("dialog_btn_normal",RAISED,(20,10,20,10),R_CTRL)
flat("dialog_btn_hover",HOVER,(20,10,20,10),R_CTRL)
flat("dialog_btn_pressed",ACCENT_DIM,(20,10,20,10),R_CTRL,BORDER["hairline"],(ACCENT[0],ACCENT[1],ACCENT[2],0.6))
flat("dialog_btn_focus",NONE,(),R_CTRL,BORDER["focus"],TEXT,center=False)
flat("primary_normal",ACCENT,(18,9,18,9),R_CTRL)
flat("primary_hover",ACCENT_HI,(18,9,18,9),R_CTRL)
flat("primary_pressed",ACCENT_PRESSED,(18,9,18,9),R_CTRL)
flat("primary_disabled",(ACCENT[0],ACCENT[1],ACCENT[2],0.14),(18,9,18,9),R_CTRL)
flat("primary_focus",NONE,(),R_CTRL,BORDER["focus"],TEXT,center=False)
flat("dprimary_normal",ACCENT,(20,10,20,10),R_CTRL)
flat("dprimary_hover",ACCENT_HI,(20,10,20,10),R_CTRL)
flat("dprimary_pressed",ACCENT_PRESSED,(20,10,20,10),R_CTRL)
flat("danger_normal",(DANGER[0],DANGER[1],DANGER[2],0.08),(20,10,20,10),R_CTRL,BORDER["hairline"],(DANGER[0],DANGER[1],DANGER[2],0.8))
flat("danger_hover",(DANGER[0],DANGER[1],DANGER[2],0.9),(20,10,20,10),R_CTRL)
flat("danger_pressed",DANGER_PRESSED,(20,10,20,10),R_CTRL)
# icon + tool buttons (square, 36)
flat("icon_normal",NONE,(6,6,6,6),R_CTRL)
flat("icon_hover",HOVER,(6,6,6,6),R_CTRL)
flat("icon_pressed",ACCENT_DIM,(6,6,6,6),R_CTRL)
flat("tool_armed",NONE,(6,6,6,6),R_CTRL,BORDER["hairline"],(ACCENT[0],ACCENT[1],ACCENT[2],0.7))
flat("tool_normal",NONE,(6,6,6,6),R_CTRL)
flat("tool_hover",HOVER,(6,6,6,6),R_CTRL)
flat("tool_pressed",ACCENT,(6,6,6,6),R_CTRL)
flat("tool_hover_pressed",ACCENT_HI,(6,6,6,6),R_CTRL)
flat("tool_disabled",NONE,(6,6,6,6),R_CTRL)
flat("switch_pressed",ACCENT_DIM,(6,6,6,6),R_CTRL)
flat("switch_hover_pressed",(ACCENT[0],ACCENT[1],ACCENT[2],0.28),(6,6,6,6),R_CTRL)
flat("tab_normal",NONE,(16,9,16,9),R_CTRL)
flat("tab_hover",COL["choice_hover"],(16,9,16,9),R_CTRL)
flat("tab_pressed",ACCENT,(16,9,16,9),R_CTRL)
flat("tab_hover_pressed",ACCENT_HI,(16,9,16,9),R_CTRL)
flat("section_normal",NONE,(0,4,0,4),R_CTRL)
flat("section_hover",COL["section_hover"],(0,4,0,4),R_CTRL,expand=(8,0,8,0))  # (the highlight reaches past the text and chevron, which stay where they are)
# segmented choices
flat("check_focus",NONE,(0,4,0,4),R_CTRL,BORDER["focus"],TEXT,center=False)
# a dropdown that is a quiet outlined field (the graph's trait choice)
flat("select_normal",NONE,(8,2,6,2),R_CTRL,BORDER["hairline"],HAIR)
flat("select_hover",COL["choice_hover"],(8,2,6,2),R_CTRL,BORDER["hairline"],COL["select_border_hover"])
flat("popup_item_hover",COL["menu_hover"],(6,3,6,3),R_CTRL)
flat("notice_panel",RAISED,(14,8,14,8),R_CTRL,BORDER["hairline"],COL["notice_border"])
flat("sw_normal",NONE,(10,1,10,1),R_CTRL)
flat("sw_hover",COL["choice_hover"],(10,1,10,1),R_CTRL)
flat("sw_pressed",ACCENT,(10,1,10,1),R_CTRL)
flat("sw_hover_pressed",ACCENT_HI,(10,1,10,1),R_CTRL)
flat("sw_segments",SUNKEN,(2,2,2,2),R_CTRL+2,BORDER["hairline"],HAIR)
flat("sw_segments_focused",SUNKEN,(2,2,2,2),R_CTRL+2,BORDER["focus"],TEXT)
flat("choice_normal",NONE,(12,4,12,4),R_CTRL)
flat("choice_hover",COL["choice_hover"],(12,4,12,4),R_CTRL)
flat("choice_pressed",ACCENT,(12,4,12,4),R_CTRL)
flat("choice_hover_pressed",ACCENT_HI,(12,4,12,4),R_CTRL)
flat("choice_disabled",NONE,(12,4,12,4),R_CTRL)
empty("bare_empty")
empty("check_empty",(0,4,0,4))
# step badges
flat("badge_plain",RAISED,(0,0,0,0),13)
flat("badge_current",ACCENT,(0,0,0,0),13)
flat("badge_done",ACCENT_DIM,(0,0,0,0),13)
flat("warn_icon",NONE,(0,0,0,0),0)
# list rows
flat("list_normal",NONE,(8,3,8,3),R_CTRL)
flat("list_hover",HOVER,(8,3,8,3),R_CTRL)
flat("list_pressed",ACCENT_DIM,(8,3,8,3),R_CTRL)
# fields
flat("edit_normal",SUNKEN,(8,5,8,5),R_CTRL,BORDER["hairline"],COL["field_border"])
flat("edit_focus",SUNKEN,(8,5,8,5),R_CTRL,BORDER["focus"],ACCENT)
flat("edit_tight",SUNKEN,(6,2,6,2),R_CTRL,BORDER["hairline"],COL["field_border"])
flat("edit_tight_focus",SUNKEN,(6,2,6,2),R_CTRL,BORDER["focus"],ACCENT)
empty("bup_name_field",(3,0,3,0))
empty("dialog_text_pad",(0,0,0,12))
# sliders / scroll / progress
flat("graph_pill",NONE,(8,2,8,2),R_CTRL,BORDER["hairline"],COL["pill_border"])
flat("graph_pill_hover",COL["pill_hover"],(8,2,8,2),R_CTRL,BORDER["hairline"],COL["pill_border_hover"])
flat("slider_focus",NONE,(0,0,0,0),R_CTRL,BORDER["focus"],ACCENT,center=False)
flat("slider_track",SUNKEN,(0,3,0,3),3,BORDER["hairline"],COL["slider_border"])
flat("slider_fill",(ACCENT[0],ACCENT[1],ACCENT[2],0.85),(0,3,0,3),3)
flat("slider_fill_hi",ACCENT,(0,3,0,3),3)
flat("scroll_track",COL["scroll_track"],(5,0,5,0),5)
flat("scroll_grabber",COL["scroll_grabber"],(5,0,5,0),5)
flat("scroll_grabber_hi",COL["scroll_grabber_hover"],(5,0,5,0),5)
flat("goal_bar_bg",SUNKEN,(0,4,0,4),4)
flat("goal_bar_fill",EMPHASIS,(0,0,0,0),4)

subs.append('''[sub_resource type="StyleBoxLine" id="sep_v"]
color = '''+rgba(COL["separator"])+'''
vertical = true
thickness = 1

[sub_resource type="StyleBoxLine" id="sep_h"]
color = '''+rgba(COL["separator"])+'''
thickness = 1
''')
def _font_ext():
    L=[]
    for w in sorted(D["typography"]["weights"],key=lambda w:(w["family"]!="mono",w["weight"])):
        L.append('[ext_resource type="FontFile"%s path="res://%s" id="%s"]'%(' uid="%s"'%w["uid"] if "uid" in w else "",w["file"],font_id(w)))
    return "\n".join(L)
FONT_EXT=_font_ext()
ext='''[gd_resource type="Theme" format=3 uid="uid://i3jbu01lnbni"]

[ext_resource type="Texture2D" path="res://icons/check_on.svg" id="check_on"]
[ext_resource type="Texture2D" path="res://icons/chevron_small.svg" id="chevron_small"]
[ext_resource type="Texture2D" path="res://icons/check_off.svg" id="check_off"]
'''+FONT_EXT+'''

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

res.append('default_font = ExtResource("%s")'%REG)
res.append('default_font_size = %d'%FS["base"])
# --- roles (type scale: 12 caption, 14 note/field, 15 body, 18 title, 22 heading, 56 display)
T("Label",colors={"font_color":TEXT})
T("Bright","Label",colors={"font_color":TEXT},fonts={"font":REG})
T("BrightFlash","Label",colors={"font_color":ACCENT_HI},fonts={"font":REG})  # the first number of a readout while it has just changed (see UiText.numbers)
T("CardTitle","Label",colors={"font_color":EMPHASIS},sizes={"font_size":FS["2xl"]},fonts={"font":LIGHT})
T("CardText","Label",colors={"font_color":TEXT},sizes={"font_size":FS["base"]},fonts={"font":LIGHT},consts={"line_spacing":3})
T("FocusLabel","Label",colors={"font_color":ACCENT})
T("Hint","Label",colors={"font_color":MUTED},sizes={"font_size":FS["s"]},fonts={"font":LIGHT})
T("Note","Label",colors={"font_color":MUTED},sizes={"font_size":FS["s"]},fonts={"font":LIGHT})
T("Unit","Label",colors={"font_color":FAINT},sizes={"font_size":FS["s"]},fonts={"font":MONO})
T("StatValue","Label",colors={"font_color":TEXT},sizes={"font_size":FS["s"]},fonts={"font":MONO})
T("Warning","Label",colors={"font_color":WARNING_TEXT},sizes={"font_size":FS["m"]},fonts={"font":EMPH})
T("WarningIcon","Button",colors={k:WARNING for k in ("icon_normal_color","icon_disabled_color","icon_hover_color","icon_pressed_color","icon_focus_color","icon_hover_pressed_color")},consts={"icon_max_width":ICON["2xl"]},styles={k:"warn_icon" for k in ("normal","disabled","hover","pressed","hover_pressed","focus")})
T("Small","Label",colors={"font_color":MUTED},sizes={"font_size":FS["s"]},fonts={"font":LIGHT})
T("SmallBright","Label",colors={"font_color":TEXT},sizes={"font_size":FS["s"]},fonts={"font":REG})
T("ReadoutLabel","Label",sizes={"font_size":FS["s"]})
T("Accent","Label",colors={"font_color":EMPHASIS},fonts={"font":REG})
T("Heading","Label",colors={"font_color":TEXT},sizes={"font_size":FS["3xl"]},fonts={"font":LIGHT})
T("Title","Label",colors={"font_color":TEXT},sizes={"font_size":FS["5xl"]},fonts={"font":LIGHT})
T("Display","Label",colors={"font_color":TEXT},sizes={"font_size":FS["6xl"]},fonts={"font":BOLD})
T("Tagline","Label",colors={"font_color":EMPHASIS},sizes={"font_size":FS["2xl"]},fonts={"font":LIGHT})
T("Story","Label",colors={"font_color":TEXT},sizes={"font_size":FS["xl"]},consts={"line_spacing":5},fonts={"font":LIGHT})
T("Notice","Label",colors={"font_color":TEXT},sizes={"font_size":FS["m"]},fonts={"font":REG},styles={"normal":"notice_panel"})
T("Banner","Label",colors={"font_color":TEXT,"font_outline_color":OUTLINE},consts={"outline_size":6},sizes={"font_size":FS["4xl"]},fonts={"font":LIGHT})
T("BupName","Label",colors={"font_color":EMPHASIS},sizes={"font_size":FS["l"]},fonts={"font":REG})
T("BupNameField","LineEdit",colors={"caret_color":EMPHASIS,"font_color":EMPHASIS},sizes={"font_size":FS["l"]},fonts={"font":REG},styles={"focus":"bup_name_field","normal":"bup_name_field"})
T("DialogTitle","Label",colors={"font_color":TEXT},sizes={"font_size":FS["2xl"]},fonts={"font":LIGHT})
T("DialogText","Label",sizes={"font_size":FS["l"]},styles={"normal":"dialog_text_pad"},fonts={"font":LIGHT})
T("TooltipLabel",colors={"font_color":TEXT},sizes={"font_size":FS["s"]})
# rich text
T("RichTextLabel",fonts={"bold_font":REG,"mono_font":MONO,"normal_font":REG})
T("Readout","RichTextLabel",colors={"default_color":TEXT},fonts={"normal_font":MONO,"bold_font":MONO_BOLD},sizes={"bold_font_size":FS["m"],"mono_font_size":FS["m"],"normal_font_size":FS["m"]})
T("Article","RichTextLabel",colors={"default_color":TEXT},fonts={"normal_font":LIGHT,"bold_font":REG,"mono_font":MONO},sizes={"bold_font_size":FS["base"],"mono_font_size":FS["m"],"normal_font_size":FS["base"]})
T("ReadoutMuted","RichTextLabel",colors={"default_color":MUTED},fonts={"normal_font":REG,"bold_font":REG},sizes={"bold_font_size":FS["m"],"mono_font_size":FS["m"],"normal_font_size":FS["m"]})
T("ReadoutAccent","RichTextLabel",colors={"default_color":EMPHASIS},fonts={"normal_font":LIGHT,"bold_font":REG},sizes={"bold_font_size":FS["m"],"mono_font_size":FS["m"],"normal_font_size":FS["m"]})
T("StoryHeading","RichTextLabel",colors={"default_color":EMPHASIS},fonts={"normal_font":LIGHT,"bold_font":REG},sizes={"bold_font_size":FS["xl"],"mono_font_size":FS["xl"],"normal_font_size":FS["xl"]})
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
T("FlushStack","VBoxContainer",consts={"separation":0})
T("SnugStack","VBoxContainer",consts={"separation":SP["snug"]})
T("TightStack","VBoxContainer",consts={"separation":SP["tight"]})
T("RoomyStack","VBoxContainer",consts={"separation":SP["roomy"]})
T("SectionStack","VBoxContainer",consts={"separation":SP["section"]})
T("SpaciousStack","VBoxContainer",consts={"separation":SP["spacious"]})
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
 sizes={"font_size":FS["base"]},fonts={"font":REG},styles={"disabled":"btn_disabled","focus":"btn_focus","hover":"btn_hover","hover_pressed":"btn_pressed","normal":"btn_normal","pressed":"btn_pressed"})
T("PrimaryButton","Button",colors={k:ON_ACCENT for k in("font_color","font_focus_color","font_hover_color","font_hover_pressed_color","font_pressed_color")},
 styles={"focus":"primary_focus","hover":"primary_hover","hover_pressed":"primary_pressed","normal":"primary_normal","pressed":"primary_pressed","disabled":"primary_disabled"})
T("SmallButton","Button",sizes={"font_size":FS["m"]},consts={"icon_max_width":ICON["s"],"h_separation":6})
T("PictureButton","Button",colors={**{k:WHITE for k in ("icon_normal_color","icon_hover_color","icon_pressed_color","icon_hover_pressed_color","icon_focus_color","icon_disabled_color")}},sizes={"font_size":FS["m"]},consts={"icon_max_width":ICON["2xl"],"h_separation":8})
T("SmallPrimaryButton","Button",colors={**{k:ON_ACCENT for k in("font_color","font_focus_color","font_hover_color","font_hover_pressed_color","font_pressed_color")},"font_disabled_color":(ACCENT[0],ACCENT[1],ACCENT[2],0.5)},
 sizes={"font_size":FS["m"]},styles={"focus":"primary_focus","hover":"primary_hover","hover_pressed":"primary_pressed","normal":"primary_normal","pressed":"primary_pressed","disabled":"primary_disabled"})
T("DialogButton","Button",sizes={"font_size":FS["base"]},styles={"focus":"dialog_btn_focus","hover":"dialog_btn_hover","hover_pressed":"dialog_btn_pressed","normal":"dialog_btn_normal","pressed":"dialog_btn_pressed"})
T("DialogPrimaryButton","Button",colors={k:ON_ACCENT for k in ("font_color","font_focus_color","font_hover_color","font_hover_pressed_color","font_pressed_color")},sizes={"font_size":FS["base"]},styles={"focus":"primary_focus","hover":"dprimary_hover","hover_pressed":"dprimary_pressed","normal":"dprimary_normal","pressed":"dprimary_pressed"})
T("DialogDangerButton","Button",colors={"font_color":DANGER_TEXT,"font_focus_color":DANGER_TEXT,"font_hover_color":ON_DANGER,"font_hover_pressed_color":ON_DANGER,"font_pressed_color":ON_DANGER},sizes={"font_size":FS["base"]},styles={"focus":"dialog_btn_focus","hover":"danger_hover","hover_pressed":"danger_pressed","normal":"danger_normal","pressed":"danger_pressed"})
T("IconButton","Button",colors={"icon_focus_color":TEXT,"icon_hover_color":TEXT,"icon_hover_pressed_color":ACCENT_HI,"icon_normal_color":MUTED,"icon_pressed_color":ACCENT},consts={"icon_max_width":ICON["m"]},styles={"hover":"icon_hover","hover_pressed":"icon_pressed","normal":"icon_normal","pressed":"icon_pressed"})
T("ToolButton","Button",colors={"icon_disabled_color":COL["icon_disabled"],"icon_normal_color":MUTED,"icon_hover_color":TEXT,"icon_focus_color":MUTED,"icon_pressed_color":ON_ACCENT,"icon_hover_pressed_color":ON_ACCENT},consts={"icon_max_width":ICON["l"]},styles={"disabled":"tool_disabled","hover":"tool_hover","hover_pressed":"tool_hover_pressed","normal":"tool_normal","pressed":"tool_pressed"})
T("ToolButtonArmed","Button",colors={"icon_disabled_color":COL["icon_disabled"],"icon_normal_color":ACCENT,"icon_hover_color":ACCENT_HI,"icon_focus_color":ACCENT,"icon_pressed_color":ON_ACCENT,"icon_hover_pressed_color":ON_ACCENT},consts={"icon_max_width":ICON["l"]},styles={"disabled":"tool_disabled","hover":"tool_hover","hover_pressed":"tool_hover_pressed","normal":"tool_armed","pressed":"tool_pressed"})
T("ToggleButton","Button",colors={"icon_disabled_color":COL["icon_disabled"],"icon_normal_color":FAINT,"icon_hover_color":MUTED,"icon_focus_color":FAINT,"icon_pressed_color":ACCENT,"icon_hover_pressed_color":ACCENT_HI},consts={"icon_max_width":ICON["l"]},styles={"disabled":"tool_disabled","hover":"tool_hover","hover_pressed":"switch_hover_pressed","normal":"tool_normal","pressed":"switch_pressed"})
T("TabButton","Button",colors={"font_color":MUTED,"font_hover_color":TEXT,"font_pressed_color":ON_ACCENT,"font_hover_pressed_color":ON_ACCENT,"font_focus_color":MUTED},sizes={"font_size":FS["base"]},styles={"disabled":"tab_normal","hover":"tab_hover","hover_pressed":"tab_hover_pressed","normal":"tab_normal","pressed":"tab_pressed"})
T("SectionButton","Button",colors={"font_color":TEXT,"font_hover_color":TEXT,"font_pressed_color":TEXT,"font_hover_pressed_color":TEXT,"font_focus_color":TEXT,"icon_normal_color":MUTED,"icon_hover_color":TEXT,"icon_pressed_color":MUTED,"icon_hover_pressed_color":TEXT,"icon_focus_color":MUTED},consts={"icon_max_width":ICON["s"],"h_separation":6},sizes={"font_size":FS["s"]},fonts={"font":REG},styles={"disabled":"section_normal","hover":"section_hover","hover_pressed":"section_hover","normal":"section_normal","pressed":"section_normal","focus":"section_normal"})
T("TraitSelect","OptionButton",colors={"font_color":ACCENT,"font_hover_color":ACCENT_HI,"font_pressed_color":ACCENT_HI,"font_hover_pressed_color":ACCENT_HI,"font_focus_color":ACCENT},sizes={"font_size":FS["s"]},fonts={"font":REG},consts={"arrow_margin":6,"h_separation":6},icons={"arrow":'ExtResource("chevron_small")'},styles={"disabled":"select_normal","focus":"btn_focus","hover":"select_hover","hover_pressed":"select_hover","normal":"select_normal","pressed":"select_hover"})
T("PopupMenu",colors={"font_color":MUTED,"font_hover_color":TEXT,"font_focus_color":TEXT,"font_accelerator_color":FAINT},sizes={"font_size":FS["s"]},fonts={"font":REG},consts={"v_separation":2,"h_separation":8,"item_start_padding":6,"item_end_padding":6},styles={"panel":"popup_panel","hover":"popup_item_hover","focus":"popup_item_hover"})
T("SwitchButton","Button",colors={"font_color":MUTED,"font_hover_color":TEXT,"font_pressed_color":ON_ACCENT,"font_hover_pressed_color":ON_ACCENT,"font_focus_color":MUTED},sizes={"font_size":FS["s"]},styles={"disabled":"sw_normal","hover":"sw_hover","hover_pressed":"sw_hover_pressed","normal":"sw_normal","pressed":"sw_pressed"})
T("ChoiceButton","Button",colors={**{k:WHITE for k in ("icon_normal_color","icon_hover_color","icon_pressed_color","icon_hover_pressed_color","icon_focus_color","icon_disabled_color")},"font_color":MUTED,"font_hover_color":TEXT,"font_pressed_color":ON_ACCENT,"font_hover_pressed_color":ON_ACCENT,"font_focus_color":MUTED},sizes={"font_size":FS["m"]},consts={"icon_max_width":ICON["xl"],"h_separation":6},styles={"disabled":"choice_disabled","hover":"choice_hover","hover_pressed":"choice_hover_pressed","normal":"choice_normal","pressed":"choice_pressed"})
T("Badge","PanelContainer",styles={"panel":"badge_plain"})
T("BadgeCurrent","PanelContainer",styles={"panel":"badge_current"})
T("BadgeDone","PanelContainer",styles={"panel":"badge_done"})
T("BadgeNumber","Label",colors={"font_color":MUTED},sizes={"font_size":FS["s"]},fonts={"font":REG})
T("BadgeNumberCurrent","Label",colors={"font_color":ON_ACCENT},sizes={"font_size":FS["s"]},fonts={"font":REG})
T("BadgeNumberDone","Label",colors={"font_color":ACCENT},sizes={"font_size":FS["s"]},fonts={"font":REG})
T("StepName","Label",colors={"font_color":MUTED},fonts={"font":REG})
T("StepNameCurrent","Label",colors={"font_color":TEXT},fonts={"font":REG})
T("StepNameDone","Label",colors={"font_color":MUTED},fonts={"font":REG})
T("ListButton","Button",colors={"font_disabled_color":EMPHASIS},sizes={"font_size":FS["base"]},styles={"disabled":"icon_normal","hover":"icon_hover","hover_pressed":"icon_pressed","normal":"icon_normal","pressed":"icon_pressed"})
T("CompactListButton","Button",colors={"font_disabled_color":EMPHASIS,"font_color":TEXT},sizes={"font_size":FS["s"]},styles={"disabled":"list_normal","hover":"list_hover","hover_pressed":"list_pressed","normal":"list_normal","pressed":"list_pressed"})
T("DeceasedListButton","Button",colors={"font_color":DECEASED_TEXT,"font_hover_color":DECEASED_TEXT_HI,"font_pressed_color":DECEASED_TEXT_HI,"font_hover_pressed_color":DECEASED_TEXT_HI},sizes={"font_size":FS["s"]},styles={"disabled":"list_normal","hover":"list_hover","hover_pressed":"list_pressed","normal":"list_normal","pressed":"list_pressed"})
T("CheckBox",colors={"font_color":TEXT,"font_hover_color":TEXT,"font_hover_pressed_color":TEXT,"font_pressed_color":TEXT},consts={"h_separation":6},sizes={"font_size":FS["s"]},
 icons={"checked":'ExtResource("check_on")',"unchecked":'ExtResource("check_off")'},styles={k:"check_empty" for k in("disabled","hover","hover_pressed","normal","pressed")})
# fields
T("LineEdit",colors={"caret_color":ACCENT,"font_color":TEXT,"selection_color":(ACCENT[0],ACCENT[1],ACCENT[2],0.35)},styles={"focus":"edit_focus","normal":"edit_normal"})
T("ReadoutField","LineEdit",consts={"minimum_character_width":1},sizes={"font_size":FS["l"]},fonts={"font":MONO},styles={"focus":"edit_tight_focus","normal":"edit_tight"})
T("CompactField","LineEdit",consts={"minimum_character_width":1},sizes={"font_size":FS["l"]},fonts={"font":MONO})
T("CompactSpinBox","SpinBox",consts={"buttons_width":12})
T("HSlider",styles={"grabber_area":"slider_fill","grabber_area_highlight":"slider_fill_hi","slider":"slider_track","focus":"slider_focus"})
T("VScrollBar",styles={"scroll":"scroll_track","scroll_focus":"scroll_track","grabber":"scroll_grabber","grabber_highlight":"scroll_grabber_hi","grabber_pressed":"scroll_grabber_hi"})
T("ColorPicker",consts={"h_width":22,"sv_height":170,"sv_width":215})
# dialogs and windows
T("AcceptDialog",consts={"buttons_min_width":96,"buttons_separation":12},sizes={"title_font_size":FS["2xl"]},styles={"panel":"dialog_panel"})
T("ConfirmationDialog",consts={"buttons_min_width":96,"buttons_separation":12},sizes={"title_font_size":FS["2xl"]},styles={"panel":"dialog_panel"})
T("Window",consts={"close_h_offset":24,"close_v_offset":34,"title_height":60},sizes={"title_font_size":FS["2xl"]},styles={"embedded_border":"embedded_border","embedded_unfocused_border":"embedded_unfocused_border"})
# graph
T("GaugeBar",colors={"track":COL["track"],"band":COL["gauge_floor"],"tick":COL["gauge_tick"],"fill":ACCENT,"limited":EMPHASIS,"starving":DANGER,"dead":FAINT})  # the bars of a bup's panel (ui/gauge_bar.gd)
T("StatLimited","Label",colors={"font_color":EMPHASIS},sizes={"font_size":FS["s"]},fonts={"font":MONO})  # a bup's reserve word while it is food-limited (ui/bup_gauges.gd)
T("StatStarving","Label",colors={"font_color":DANGER},sizes={"font_size":FS["s"]},fonts={"font":MONO})  # ... and while it is starving
T("StatLeader",colors={"line":COL["stat_leader"]})  # the dotted line between a stat's name and its value (ui/stat_leader.gd)
T("GenomeSlot",colors={"track":COL["track"],"symbol":ON_BAND,"symbol_dim":COL["gene_symbol_dim"]},sizes={"font_size":FS["xs"]},fonts={"font":MONO})  # the chromosome map's slots (ui/genome_slot.gd)
T("GenomeGrid","GridContainer",consts={"h_separation":10,"v_separation":0})
T("HistoryGraph",styles={"pill":"graph_pill","pill_hover":"graph_pill_hover"},fonts={"font":MONO},colors={"background":(*SURFACE[:3],0.0),"border":(*WHITE[:3],0.0),"grid":COL["grid"],"grid_faint":COL["grid_faint"],"muted":MUTED,"population":EMPHASIS,"trait":ACCENT},sizes={"legend":FS["s"],"tick":FS["xs"]})

text=ext+"\n".join(subs)+"\n[resource]\n"+"\n".join(res)+"\n"
if "--check" in sys.argv:  # exit 1 when scenes/menu_theme.tres is not what the tokens and variations here make
    sys.exit(0 if open("scenes/menu_theme.tres").read()==text else 1)
open("scenes/menu_theme.tres","w").write(text)
