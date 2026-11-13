use super::super::generic::{Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::{ident_end, word_start};
use super::{no_hints, LanguageDef};

/// Uniform hints (`: source_color, hint_range(0, 1)`).
static HINTS: &[&str] = &[
    "source_color",
    "hint_range",
    "hint_enum",
    "hint_normal",
    "hint_default_white",
    "hint_default_black",
    "hint_default_transparent",
    "hint_anisotropy",
    "hint_roughness_r",
    "hint_roughness_g",
    "hint_roughness_b",
    "hint_roughness_a",
    "hint_roughness_normal",
    "hint_roughness_gray",
    "hint_screen_texture",
    "hint_normal_roughness_texture",
    "hint_depth_texture",
    "filter_nearest",
    "filter_linear",
    "filter_nearest_mipmap",
    "filter_linear_mipmap",
    "filter_nearest_mipmap_anisotropic",
    "filter_linear_mipmap_anisotropic",
    "repeat_enable",
    "repeat_disable",
    "instance_index",
];

/// Built-in variables of the shader stages.
static BUILTINS: &[&str] = &[
    "ALBEDO",
    "ALPHA",
    "ALPHA_SCISSOR_THRESHOLD",
    "AO",
    "ATTENUATION",
    "BINORMAL",
    "CAMERA_POSITION_WORLD",
    "CLEARCOAT",
    "COLOR",
    "DIFFUSE_LIGHT",
    "EMISSION",
    "EXPOSURE",
    "FRAGCOORD",
    "INSTANCE_CUSTOM",
    "INSTANCE_ID",
    "INV_VIEW_MATRIX",
    "LIGHT",
    "LIGHT_COLOR",
    "LIGHT_VERTEX",
    "METALLIC",
    "MODEL_MATRIX",
    "MODELVIEW_MATRIX",
    "NORMAL",
    "NORMAL_MAP",
    "POINT_COORD",
    "POINT_SIZE",
    "POSITION",
    "PROJECTION_MATRIX",
    "RIM",
    "ROUGHNESS",
    "SCREEN_PIXEL_SIZE",
    "SCREEN_UV",
    "SPECULAR",
    "SPECULAR_LIGHT",
    "TANGENT",
    "TEXTURE",
    "TEXTURE_PIXEL_SIZE",
    "TIME",
    "UV",
    "UV2",
    "VERTEX",
    "VERTEX_ID",
    "VIEW",
    "VIEW_MATRIX",
];

static SPEC: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    doc_blocks: true,
    strings: &[Str::new("\"", "\"", BACKSLASH)],
    keywords: &[
        "shader_type",
        "render_mode",
        "stencil_mode",
        "uniform",
        "varying",
        "instance",
        "global",
        "const",
        "struct",
        "in",
        "out",
        "inout",
        "flat",
        "smooth",
        "lowp",
        "mediump",
        "highp",
        "group_uniforms",
    ],
    control_keywords: &[
        "break", "case", "continue", "default", "discard", "do", "else", "for", "if", "return",
        "switch", "while",
    ],
    types: super::glsl::TYPES,
    constants: &["true", "false", "PI", "TAU", "E"],
    variables: BUILTINS,
    caps_constants: true,
    capitalized_types: true,
    calls: true,
    definitions: &[
        ("struct", TokenKind::Type),
        ("shader_type", TokenKind::Type),
    ],
    hash_words: true,
    hook: Some(hints),
    ..Spec::EMPTY
};

/// Uniform hints, and the flags of a `render_mode` line.
fn hints(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    if !word_start(chars, i) || !chars[i].is_alphabetic() {
        return None;
    }
    let end = ident_end(chars, i);
    let word: String = chars[i..end].iter().collect();
    if HINTS.contains(&word.as_str()) {
        cx.push(i, end, TokenKind::Annotation);
        return Some(end);
    }
    let first = (0..i).find(|&j| !chars[j].is_whitespace())?;
    let render_mode = cx.starts_with(first, "render_mode") && first + "render_mode".len() < i;
    if render_mode {
        cx.push(i, end, TokenKind::Attribute);
        return Some(end);
    }
    None
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static GODOT_SHADER: LanguageDef = LanguageDef {
    id: "godot_shader",
    name: "Godot shader",
    extensions: &["gdshader", "gdshaderinc"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
