Two typefaces, both under the SIL Open Font License 1.1 (the license texts must stay with the font files whenever the game is distributed):

IBM Plex Sans - https://github.com/IBM/plex - weights 300, 400, 500, 700. All interface text: Light (300) for long text and big type, Regular (400) for buttons, labels and everything you act on, Medium (500) only for the warning, Bold (700) only for the game's name on the title screen. License: OFL-IBMPlex.txt.
Commit Mono (v1.143) by Eigil Nikolajsen - https://commitmono.com - weights 500, 700. Numbers: stat values, units, the graph, the readouts and number fields, where digits must line up. License: OFL.txt.

Which one a piece of text uses, and in which weight, is set in tools/gen_theme.py (which writes scenes/menu_theme.tres), never anywhere else.
