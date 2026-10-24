//! `cargo xtask themes`: writes `godot/themes/{dark,light}.tres` from one
//! palette per theme, so both themes always define the same items.

use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use anyhow::Result;

type Rgb = (f64, f64, f64);

struct Palette {
    name: &'static str,
    bg: Rgb,
    bg_alt: Rgb,
    surface: Rgb,
    hover: Rgb,
    pressed: Rgb,
    border: Rgb,
    text: Rgb,
    dim: Rgb,
    accent: Rgb,
    selection: Rgb,
    selection_soft: Rgb,
    error: Rgb,
    head: Rgb,
    lanes: [Rgb; 8],
    label_head: Rgb,
    label_branch: Rgb,
    label_remote: Rgb,
    label_tag: Rgb,
    label_text: Rgb,
    added: Rgb,
    removed: Rgb,
    modified: Rgb,
    renamed: Rgb,
    added_bg: Rgb,
    removed_bg: Rgb,
    hunk_bg: Rgb,
    added_hl_bg: Rgb,
    removed_hl_bg: Rgb,
    syntax_keyword: Rgb,
    syntax_type: Rgb,
    syntax_string: Rgb,
    syntax_number: Rgb,
}

const DARK: Palette = Palette {
    name: "dark",
    bg: (0.118, 0.125, 0.141),
    bg_alt: (0.094, 0.1, 0.114),
    surface: (0.165, 0.176, 0.2),
    hover: (0.21, 0.224, 0.25),
    pressed: (0.25, 0.265, 0.3),
    border: (0.24, 0.255, 0.29),
    text: (0.88, 0.9, 0.93),
    dim: (0.55, 0.58, 0.63),
    accent: (0.33, 0.58, 0.98),
    selection: (0.2, 0.32, 0.52),
    selection_soft: (0.17, 0.23, 0.33),
    error: (0.95, 0.45, 0.45),
    head: (0.45, 0.8, 0.55),
    lanes: [
        (0.3, 0.6, 1.0),
        (0.36, 0.8, 0.45),
        (1.0, 0.62, 0.25),
        (0.7, 0.5, 1.0),
        (0.95, 0.38, 0.42),
        (0.25, 0.8, 0.8),
        (0.92, 0.8, 0.3),
        (0.95, 0.5, 0.75),
    ],
    label_head: (0.24, 0.5, 0.32),
    label_branch: (0.22, 0.36, 0.6),
    label_remote: (0.3, 0.3, 0.36),
    label_tag: (0.5, 0.4, 0.18),
    label_text: (0.95, 0.96, 0.98),
    added: (0.45, 0.8, 0.5),
    removed: (0.95, 0.45, 0.45),
    modified: (0.9, 0.72, 0.35),
    renamed: (0.45, 0.7, 1.0),
    added_bg: (0.13, 0.24, 0.16),
    removed_bg: (0.27, 0.14, 0.15),
    hunk_bg: (0.14, 0.17, 0.23),
    added_hl_bg: (0.2, 0.42, 0.25),
    removed_hl_bg: (0.48, 0.2, 0.22),
    syntax_keyword: (0.78, 0.55, 0.95),
    syntax_type: (0.4, 0.78, 0.85),
    syntax_string: (0.6, 0.82, 0.5),
    syntax_number: (0.95, 0.65, 0.4),
};

const LIGHT: Palette = Palette {
    name: "light",
    bg: (0.98, 0.98, 0.985),
    bg_alt: (0.945, 0.95, 0.96),
    surface: (1.0, 1.0, 1.0),
    hover: (0.91, 0.925, 0.95),
    pressed: (0.86, 0.88, 0.92),
    border: (0.8, 0.82, 0.86),
    text: (0.11, 0.12, 0.14),
    dim: (0.42, 0.45, 0.5),
    accent: (0.13, 0.4, 0.85),
    selection: (0.78, 0.86, 0.98),
    selection_soft: (0.86, 0.91, 0.99),
    error: (0.78, 0.16, 0.16),
    head: (0.1, 0.5, 0.22),
    lanes: [
        (0.13, 0.42, 0.85),
        (0.12, 0.6, 0.25),
        (0.88, 0.45, 0.05),
        (0.52, 0.3, 0.86),
        (0.85, 0.2, 0.27),
        (0.05, 0.6, 0.62),
        (0.72, 0.58, 0.05),
        (0.85, 0.28, 0.6),
    ],
    label_head: (0.2, 0.6, 0.3),
    label_branch: (0.22, 0.46, 0.85),
    label_remote: (0.5, 0.53, 0.6),
    label_tag: (0.75, 0.55, 0.1),
    label_text: (1.0, 1.0, 1.0),
    added: (0.1, 0.55, 0.2),
    removed: (0.78, 0.16, 0.16),
    modified: (0.7, 0.45, 0.0),
    renamed: (0.13, 0.4, 0.85),
    added_bg: (0.88, 0.97, 0.89),
    removed_bg: (0.99, 0.9, 0.9),
    hunk_bg: (0.92, 0.94, 0.98),
    added_hl_bg: (0.67, 0.92, 0.7),
    removed_hl_bg: (0.98, 0.72, 0.72),
    syntax_keyword: (0.55, 0.2, 0.7),
    syntax_type: (0.0, 0.45, 0.55),
    syntax_string: (0.15, 0.5, 0.1),
    syntax_number: (0.7, 0.35, 0.0),
};

/// Monospace fonts tried in order (the first one installed wins).
const MONO_FONTS: &[&str] = &[
    "JetBrains Mono",
    "Cascadia Mono",
    "Consolas",
    "SF Mono",
    "Menlo",
    "DejaVu Sans Mono",
    "Liberation Mono",
    "monospace",
];

pub fn run(themes_dir: &Path) -> Result<()> {
    for palette in [&DARK, &LIGHT] {
        let path = themes_dir.join(format!("{}.tres", palette.name));
        fs::write(&path, generate(palette))?;
        println!("wrote {}", path.display());
    }
    Ok(())
}

fn col(c: Rgb) -> String {
    col_a(c, 1.0)
}

fn col_a(c: Rgb, a: f64) -> String {
    format!("Color({}, {}, {}, {})", c.0, c.1, c.2, a)
}

/// A StyleBoxFlat description.
#[derive(Default, Clone, Copy)]
struct Flat {
    bg: Option<Rgb>,
    border: Option<Rgb>,
    width: u32,
    radius: u32,
    margins: [f64; 4],
    /// Border sides (left, top, right, bottom); all when `None`.
    sides: Option<[bool; 4]>,
    no_center: bool,
}

fn flat(bg: Rgb) -> Flat {
    Flat {
        bg: Some(bg),
        ..Flat::default()
    }
}

fn boxed(bg: Rgb, border: Rgb, width: u32, radius: u32, margins: [f64; 4]) -> Flat {
    Flat {
        bg: Some(bg),
        border: Some(border),
        width,
        radius,
        margins,
        ..Flat::default()
    }
}

fn outline(border: Rgb, width: u32, radius: u32) -> Flat {
    Flat {
        border: Some(border),
        width,
        radius,
        no_center: true,
        ..Flat::default()
    }
}

impl Flat {
    fn margins(mut self, margins: [f64; 4]) -> Self {
        self.margins = margins;
        self
    }

    fn radius(mut self, radius: u32) -> Self {
        self.radius = radius;
        self
    }

    fn border(mut self, border: Rgb, width: u32, sides: [bool; 4]) -> Self {
        self.border = Some(border);
        self.width = width;
        self.sides = Some(sides);
        self
    }
}

const TOP: [bool; 4] = [false, true, false, false];
const BOTTOM: [bool; 4] = [false, false, false, true];

struct Theme {
    subs: Vec<String>,
    items: Vec<String>,
}

impl Theme {
    fn item(&mut self, key: &str, value: impl std::fmt::Display) {
        self.items.push(format!("{key} = {value}"));
    }

    fn base(&mut self, variation: &str, of: &str) {
        self.item(&format!("{variation}/base_type"), format!("&\"{of}\""));
    }

    fn sub(&mut self, body: String) -> String {
        let id = format!("sb_{}", self.subs.len());
        self.subs.push(body.replace("{id}", &id));
        format!("SubResource(\"{id}\")")
    }

    fn style(&mut self, f: Flat) -> String {
        let mut lines = vec!["[sub_resource type=\"StyleBoxFlat\" id=\"{id}\"]".to_owned()];
        if f.no_center {
            lines.push("draw_center = false".to_owned());
        }
        if let Some(bg) = f.bg {
            lines.push(format!("bg_color = {}", col(bg)));
        }
        if let Some(border) = f.border {
            lines.push(format!("border_color = {}", col(border)));
            let sides = f.sides.unwrap_or([true; 4]);
            for (side, on) in ["left", "top", "right", "bottom"].iter().zip(sides) {
                if on {
                    lines.push(format!("border_width_{side} = {}", f.width));
                }
            }
        }
        if f.radius > 0 {
            for corner in ["top_left", "top_right", "bottom_right", "bottom_left"] {
                lines.push(format!("corner_radius_{corner} = {}", f.radius));
            }
        }
        for (side, v) in ["left", "top", "right", "bottom"].iter().zip(f.margins) {
            if v != 0.0 {
                lines.push(format!("content_margin_{side} = {v}"));
            }
        }
        self.sub(lines.join("\n"))
    }

    fn empty(&mut self) -> String {
        self.sub("[sub_resource type=\"StyleBoxEmpty\" id=\"{id}\"]".to_owned())
    }

    fn styled(&mut self, key: &str, f: Flat) {
        let style = self.style(f);
        self.item(key, style);
    }

    fn emptied(&mut self, key: &str) {
        let style = self.empty();
        self.item(key, style);
    }
}

fn generate(p: &Palette) -> String {
    let mut t = Theme {
        subs: Vec::new(),
        items: Vec::new(),
    };
    let icon = if p.name == "dark" {
        "close_on_dark"
    } else {
        "close_on_light"
    };
    let mono = t.sub(format!(
        "[sub_resource type=\"SystemFont\" id=\"{{id}}\"]\nfont_names = PackedStringArray({})",
        MONO_FONTS
            .iter()
            .map(|f| format!("\"{f}\""))
            .collect::<Vec<_>>()
            .join(", ")
    ));

    t.item("TabBar/icons/close", "ExtResource(\"icon_close\")");
    t.item("default_font_size", 14);
    for ty in [
        "Label",
        "Button",
        "LineEdit",
        "TextEdit",
        "Tree",
        "ItemList",
        "TabBar",
        "PopupMenu",
        "TooltipLabel",
        "CheckBox",
    ] {
        t.item(&format!("{ty}/colors/font_color"), col(p.text));
    }
    t.styled("PanelContainer/styles/panel", flat(p.bg));
    t.styled("Panel/styles/panel", flat(p.bg));
    for d in ["AcceptDialog", "ConfirmationDialog"] {
        t.styled(&format!("{d}/styles/panel"), flat(p.bg).margins([10.0; 4]));
    }
    t.styled(
        "PopupMenu/styles/panel",
        boxed(p.surface, p.border, 1, 4, [6.0; 4]),
    );
    t.styled(
        "PopupMenu/styles/hover",
        flat(p.selection).radius(3).margins([6.0, 2.0, 6.0, 2.0]),
    );
    t.item("PopupMenu/colors/font_hover_color", col(p.text));
    t.styled(
        "TooltipPanel/styles/panel",
        boxed(p.surface, p.border, 1, 4, [8.0, 4.0, 8.0, 4.0]),
    );

    let button = [10.0, 4.0, 10.0, 4.0];
    t.styled(
        "Button/styles/normal",
        boxed(p.surface, p.border, 1, 4, button),
    );
    t.styled(
        "Button/styles/hover",
        boxed(p.hover, p.border, 1, 4, button),
    );
    t.styled(
        "Button/styles/pressed",
        boxed(p.pressed, p.border, 1, 4, button),
    );
    t.styled(
        "Button/styles/disabled",
        boxed(p.bg_alt, p.border, 1, 4, button),
    );
    t.styled("Button/styles/focus", outline(p.accent, 1, 4));
    for k in [
        "font_hover_color",
        "font_pressed_color",
        "font_focus_color",
        "font_hover_pressed_color",
    ] {
        t.item(&format!("Button/colors/{k}"), col(p.text));
    }
    t.item("Button/colors/font_disabled_color", col(p.dim));

    let field = [8.0, 5.0, 8.0, 5.0];
    for ty in ["LineEdit", "TextEdit"] {
        t.styled(
            &format!("{ty}/styles/normal"),
            boxed(p.surface, p.border, 1, 4, field),
        );
        t.styled(&format!("{ty}/styles/focus"), outline(p.accent, 1, 4));
        t.styled(
            &format!("{ty}/styles/read_only"),
            boxed(p.bg_alt, p.border, 1, 4, field),
        );
        t.item(&format!("{ty}/colors/font_placeholder_color"), col(p.dim));
        t.item(&format!("{ty}/colors/caret_color"), col(p.text));
        t.item(&format!("{ty}/colors/selection_color"), col(p.selection));
    }
    t.item("LineEdit/colors/clear_button_color", col(p.dim));
    t.item("TextEdit/colors/font_readonly_color", col(p.text));

    for k in [
        "font_hover_color",
        "font_pressed_color",
        "font_focus_color",
        "font_hover_pressed_color",
    ] {
        t.item(&format!("CheckBox/colors/{k}"), col(p.text));
    }
    t.item("CheckBox/colors/font_disabled_color", col(p.dim));
    for state in ["normal", "pressed", "hover", "hover_pressed", "disabled"] {
        t.emptied(&format!("CheckBox/styles/{state}"));
    }
    t.styled("CheckBox/styles/focus", outline(p.accent, 1, 4));

    t.styled("Tree/styles/panel", flat(p.bg_alt));
    t.emptied("Tree/styles/focus");
    t.styled("Tree/styles/selected", flat(p.selection_soft));
    t.styled("Tree/styles/selected_focus", flat(p.selection));
    t.emptied("Tree/styles/cursor");
    t.emptied("Tree/styles/cursor_unfocused");
    t.styled("Tree/styles/hovered", flat(p.hover));
    for (state, colour) in [("normal", p.bg), ("hover", p.hover), ("pressed", p.pressed)] {
        t.styled(
            &format!("Tree/styles/title_button_{state}"),
            flat(colour)
                .border(p.border, 1, BOTTOM)
                .margins([6.0, 3.0, 6.0, 3.0]),
        );
    }
    t.item("Tree/colors/font_selected_color", col(p.text));
    t.item("Tree/colors/font_hovered_color", col(p.text));
    t.item("Tree/colors/title_button_color", col(p.dim));
    t.item("Tree/colors/guide_color", col_a(p.border, 0.0));
    t.item("Tree/colors/relationship_line_color", col_a(p.border, 0.0));
    t.item("Tree/constants/v_separation", 3);
    t.item("Tree/constants/item_margin", 14);
    t.item("Tree/constants/inner_item_margin_left", 4);
    t.item("Tree/constants/inner_item_margin_right", 6);

    t.styled("ItemList/styles/panel", flat(p.bg_alt).margins([4.0; 4]));
    t.emptied("ItemList/styles/focus");
    t.styled("ItemList/styles/selected", flat(p.selection_soft).radius(3));
    t.styled(
        "ItemList/styles/selected_focus",
        flat(p.selection).radius(3),
    );
    t.styled("ItemList/styles/hovered", flat(p.hover).radius(3));
    t.emptied("ItemList/styles/cursor");
    t.emptied("ItemList/styles/cursor_unfocused");
    t.item("ItemList/colors/font_selected_color", col(p.text));
    t.item("ItemList/colors/font_hovered_color", col(p.text));
    t.item("ItemList/constants/v_separation", 6);

    let tab = [12.0, 6.0, 8.0, 6.0];
    t.styled(
        "TabBar/styles/tab_selected",
        flat(p.bg).border(p.accent, 2, TOP).margins(tab),
    );
    t.styled("TabBar/styles/tab_unselected", flat(p.bg_alt).margins(tab));
    t.styled("TabBar/styles/tab_hovered", flat(p.hover).margins(tab));
    t.emptied("TabBar/styles/tab_focus");
    t.item("TabBar/colors/font_selected_color", col(p.text));
    t.item("TabBar/colors/font_unselected_color", col(p.dim));
    t.item("TabBar/colors/font_hovered_color", col(p.text));
    t.item("TabBar/colors/drop_mark_color", col(p.accent));
    t.base("TabStrip", "PanelContainer");
    t.styled("TabStrip/styles/panel", flat(p.bg_alt));

    for o in ["VScrollBar", "HScrollBar"] {
        t.styled(
            &format!("{o}/styles/scroll"),
            flat(p.bg_alt).margins([3.0; 4]),
        );
        let grabber = |c: Rgb| flat(c).radius(4).margins([4.0; 4]);
        t.styled(&format!("{o}/styles/grabber"), grabber(p.border));
        t.styled(&format!("{o}/styles/grabber_highlight"), grabber(p.dim));
        t.styled(&format!("{o}/styles/grabber_pressed"), grabber(p.dim));
    }
    for o in ["HSplitContainer", "VSplitContainer"] {
        t.item(&format!("{o}/constants/separation"), 4);
    }

    t.base("DimLabel", "Label");
    t.item("DimLabel/colors/font_color", col(p.dim));
    t.base("HeaderLabel", "Label");
    t.item("HeaderLabel/font_sizes/font_size", 30);
    t.base("StatusBar", "PanelContainer");
    t.styled(
        "StatusBar/styles/panel",
        flat(p.bg_alt)
            .border(p.border, 1, TOP)
            .margins([8.0, 3.0, 8.0, 3.0]),
    );
    t.base("WelcomeBox", "VBoxContainer");
    t.item("WelcomeBox/constants/separation", 14);
    t.base("RecentList", "ItemList");
    t.base("PalettePanel", "PanelContainer");
    t.styled(
        "PalettePanel/styles/panel",
        boxed(p.surface, p.border, 1, 6, [8.0; 4]),
    );
    t.base("ToastPanel", "PanelContainer");
    t.styled(
        "ToastPanel/styles/panel",
        boxed(p.surface, p.error, 1, 6, [10.0, 6.0, 6.0, 6.0]),
    );
    t.base("SidebarTree", "Tree");
    t.base("SidebarSplit", "HSplitContainer");

    t.item("CommandPalette/constants/width", 640);
    t.item("CommandPalette/constants/height", 380);
    t.item("CommandPalette/constants/top", 56);
    t.item("Toasts/constants/seconds", 6);
    t.item("Toasts/constants/width", 360);
    t.base("ShellLayout", "VBoxContainer");
    t.item("ShellLayout/constants/separation", 0);
    t.item("Shell/constants/max_tab_width", 320);
    t.item("RepoSidebar/colors/section_color", col(p.dim));
    t.item("RepoSidebar/colors/badge_color", col(p.dim));
    t.item("RepoSidebar/colors/head_color", col(p.head));
    t.item("RepoSidebar/constants/width", 260);
    t.item("RepoSidebar/constants/badge_width", 72);
    t.item("GitLogPanel/colors/error_color", col(p.error));
    t.item("GitLogPanel/constants/time_width", 80);
    t.item("GitLogPanel/constants/repo_width", 140);
    t.item("GitLogPanel/constants/result_width", 150);
    t.item("GitLogPanel/constants/height", 200);
    t.item("VirtualList/colors/selection_color", col(p.selection));
    t.item("VirtualList/colors/cursor_color", col_a(p.accent, 0.9));
    t.item("VirtualList/constants/row_height", 24);
    for (i, c) in p.lanes.iter().enumerate() {
        t.item(&format!("GraphView/colors/lane_{i}"), col(*c));
    }
    t.item("GraphView/colors/node_outline", col(p.bg));
    t.item("GraphView/constants/lane_width", 14);
    t.item("GraphView/constants/line_width", 2);
    t.item("GraphView/constants/max_lanes", 24);
    t.item("GraphView/constants/node_radius", 4);
    t.item("CommitList/colors/subject_color", col(p.text));
    for k in ["author_color", "hash_color", "date_color"] {
        t.item(&format!("CommitList/colors/{k}"), col(p.dim));
    }
    t.item("CommitList/colors/label_color", col(p.label_text));
    t.item("CommitList/constants/author_width", 160);
    t.item("CommitList/constants/date_width", 130);
    t.item("CommitList/constants/hash_width", 64);
    t.item("CommitList/constants/padding", 8);
    t.item("CommitList/constants/label_gap", 4);
    t.item("CommitList/font_sizes/label_font_size", 12);
    for (k, c) in [
        ("head", p.label_head),
        ("branch", p.label_branch),
        ("remote", p.label_remote),
        ("tag", p.label_tag),
    ] {
        t.styled(
            &format!("CommitList/styles/label_{k}"),
            flat(c).radius(3).margins([5.0, 1.0, 5.0, 1.0]),
        );
    }

    // Changes panel (M4a).
    t.base("ViewSwitch", "HBoxContainer");
    t.item("ViewSwitch/constants/separation", 4);
    t.base("ViewBar", "PanelContainer");
    t.styled(
        "ViewBar/styles/panel",
        flat(p.bg)
            .border(p.border, 1, BOTTOM)
            .margins([8.0, 4.0, 8.0, 4.0]),
    );
    t.base("DiffHeader", "PanelContainer");
    t.styled(
        "DiffHeader/styles/panel",
        flat(p.bg).margins([8.0, 4.0, 8.0, 4.0]),
    );
    t.base("SectionHeader", "Label");
    t.item("SectionHeader/colors/font_color", col(p.dim));
    t.item("SectionHeader/font_sizes/font_size", 12);
    t.base("ErrorOutput", "TextEdit");
    t.item("ErrorOutput/colors/font_readonly_color", col(p.error));
    t.item("ErrorOutput/fonts/font", &mono);
    t.item("ErrorOutput/font_sizes/font_size", 12);
    t.base("CommitSummary", "Label");
    t.item("CommitSummary/font_sizes/font_size", 16);
    t.item("CommitDetails/constants/details_height", 300);
    t.item("CommitDetails/constants/files_width", 340);
    t.item("CommitDetails/constants/body_height", 80);
    // Sync, branches and tags (M5).
    t.base("ErrorLabel", "Label");
    t.item("ErrorLabel/colors/font_color", col(p.error));
    t.item("FormDialog/constants/width", 440);
    t.item("FormDialog/constants/text_height", 90);
    t.item("FormDialog/constants/note_width", 400);
    t.item("FormDialog/constants/separation", 6);
    t.styled(
        "ProgressBar/styles/background",
        flat(p.border).radius(3).margins([0.0, 3.0, 0.0, 3.0]),
    );
    t.styled("ProgressBar/styles/fill", flat(p.accent).radius(3));
    t.item("JobsBar/constants/progress_width", 140);
    t.item("JobsBar/constants/label_width", 380);
    t.item("JobsBar/constants/separation", 8);
    t.item("ChangesView/constants/files_width", 360);
    t.item("ChangesView/constants/separation", 6);
    t.item("CommitBox/constants/body_height", 96);
    t.item("CommitBox/constants/output_height", 120);
    t.item("ChangeList/colors/path_color", col(p.text));
    t.item("ChangeList/colors/dir_color", col(p.dim));
    for (k, c) in [
        ("added", p.added),
        ("modified", p.modified),
        ("deleted", p.removed),
        ("renamed", p.renamed),
        ("untracked", p.added),
        ("conflict", p.error),
    ] {
        t.item(&format!("ChangeList/colors/{k}_color"), col(c));
    }
    t.item("ChangeList/constants/padding", 8);
    t.item("ChangeList/constants/code_width", 18);
    t.item("DiffView/fonts/font", &mono);
    t.item("DiffView/font_sizes/font_size", 13);
    t.item("DiffView/colors/text_color", col(p.text));
    t.item("DiffView/colors/line_number_color", col(p.dim));
    t.item("DiffView/colors/hunk_color", col(p.dim));
    t.item("DiffView/colors/hunk_bg", col(p.hunk_bg));
    t.item("DiffView/colors/added_bg", col(p.added_bg));
    t.item("DiffView/colors/removed_bg", col(p.removed_bg));
    t.item("DiffView/colors/added_mark", col(p.added));
    t.item("DiffView/colors/removed_mark", col(p.removed));
    t.item("DiffView/colors/gutter_bg", col(p.bg_alt));
    t.item("DiffView/colors/empty_bg", col(p.bg_alt));
    t.item("DiffView/colors/added_hl_bg", col(p.added_hl_bg));
    t.item("DiffView/colors/removed_hl_bg", col(p.removed_hl_bg));
    for (k, c) in [
        ("keyword", p.syntax_keyword),
        ("type", p.syntax_type),
        ("string", p.syntax_string),
        ("number", p.syntax_number),
        ("comment", p.dim),
    ] {
        t.item(&format!("DiffView/colors/syntax_{k}"), col(c));
    }
    t.item("DiffView/colors/message_color", col(p.dim));
    t.item("DiffView/constants/row_height", 20);
    t.item("DiffView/constants/padding", 8);

    let mut out = String::new();
    let _ = writeln!(
        out,
        "[gd_resource type=\"Theme\" load_steps={} format=3]\n",
        t.subs.len() + 2
    );
    let _ = writeln!(
        out,
        "[ext_resource type=\"Texture2D\" path=\"res://themes/icons/{icon}.svg\" id=\"icon_close\"]\n"
    );
    for sub in &t.subs {
        let _ = writeln!(out, "{sub}\n");
    }
    out.push_str("[resource]\n");
    for item in &t.items {
        out.push_str(item);
        out.push('\n');
    }
    out
}
