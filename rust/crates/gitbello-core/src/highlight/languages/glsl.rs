use super::super::generic::{Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::{ident_end, word_start};
use super::{no_hints, LanguageDef};

/// Types of GLSL and HLSL, shared with Godot shaders.
pub(super) static TYPES: &[&str] = &[
    "bool",
    "int",
    "uint",
    "float",
    "double",
    "void",
    "half",
    "vec2",
    "vec3",
    "vec4",
    "ivec2",
    "ivec3",
    "ivec4",
    "uvec2",
    "uvec3",
    "uvec4",
    "bvec2",
    "bvec3",
    "bvec4",
    "dvec2",
    "dvec3",
    "dvec4",
    "mat2",
    "mat3",
    "mat4",
    "mat2x2",
    "mat2x3",
    "mat2x4",
    "mat3x2",
    "mat3x3",
    "mat3x4",
    "mat4x2",
    "mat4x3",
    "mat4x4",
    "sampler2D",
    "sampler3D",
    "samplerCube",
    "sampler2DArray",
    "sampler2DShadow",
    "isampler2D",
    "usampler2D",
    "image2D",
    "float2",
    "float3",
    "float4",
    "float2x2",
    "float3x3",
    "float4x4",
    "int2",
    "int3",
    "int4",
    "uint2",
    "uint3",
    "uint4",
    "half2",
    "half3",
    "half4",
    "bool2",
    "bool3",
    "bool4",
];

static SPEC: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    doc_blocks: true,
    strings: &[Str::new("\"", "\"", BACKSLASH)],
    keywords: &[
        "attribute",
        "buffer",
        "cbuffer",
        "centroid",
        "coherent",
        "const",
        "flat",
        "groupshared",
        "highp",
        "in",
        "inline",
        "inout",
        "invariant",
        "layout",
        "lowp",
        "mediump",
        "noperspective",
        "out",
        "packoffset",
        "precision",
        "readonly",
        "register",
        "restrict",
        "shared",
        "smooth",
        "static",
        "struct",
        "tbuffer",
        "uniform",
        "varying",
        "volatile",
        "writeonly",
    ],
    control_keywords: &[
        "break", "case", "continue", "default", "discard", "do", "else", "for", "if", "return",
        "switch", "while",
    ],
    types: TYPES,
    constants: &["true", "false"],
    caps_constants: true,
    capitalized_types: true,
    calls: true,
    definitions: &[("struct", TokenKind::Type)],
    hash_words: true,
    hook: Some(builtins),
    ..Spec::EMPTY
};

/// `gl_*` built-in variables and HLSL `SV_*` semantics.
fn builtins(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    if !word_start(chars, i) {
        return None;
    }
    let kind = if cx.starts_with(i, "gl_") {
        TokenKind::Variable
    } else if cx.starts_with(i, "SV_") {
        TokenKind::Annotation
    } else {
        return None;
    };
    let end = ident_end(chars, i);
    cx.push(i, end, kind);
    Some(end)
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static GLSL: LanguageDef = LanguageDef {
    id: "glsl",
    name: "GLSL/HLSL",
    extensions: &[
        "glsl", "vert", "frag", "comp", "geom", "tesc", "tese", "hlsl", "hlsli", "fx",
    ],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
