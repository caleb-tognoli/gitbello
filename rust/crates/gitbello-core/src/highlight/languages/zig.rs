use super::super::generic::{Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::{ident_end, scan_while, string_end, word_start};
use super::{no_hints, LanguageDef};

static SPEC: Spec = Spec {
    line_comments: &["//"],
    doc_comments: &["///", "//!"],
    strings: &[Str::new("\"", "\"", BACKSLASH)],
    char_literals: true,
    keywords: &[
        "addrspace",
        "align",
        "allowzero",
        "and",
        "anyframe",
        "anytype",
        "asm",
        "callconv",
        "comptime",
        "const",
        "enum",
        "error",
        "export",
        "extern",
        "fn",
        "inline",
        "linksection",
        "noalias",
        "noinline",
        "nosuspend",
        "opaque",
        "or",
        "orelse",
        "packed",
        "pub",
        "struct",
        "test",
        "threadlocal",
        "union",
        "usingnamespace",
        "var",
        "volatile",
    ],
    control_keywords: &[
        "async",
        "await",
        "break",
        "catch",
        "continue",
        "defer",
        "else",
        "errdefer",
        "for",
        "if",
        "resume",
        "return",
        "suspend",
        "switch",
        "try",
        "unreachable",
        "while",
    ],
    types: &[
        "anyerror",
        "anyopaque",
        "bool",
        "c_char",
        "c_int",
        "c_long",
        "c_longdouble",
        "c_longlong",
        "c_short",
        "c_uint",
        "c_ulong",
        "c_ulonglong",
        "c_ushort",
        "comptime_float",
        "comptime_int",
        "f16",
        "f32",
        "f64",
        "f80",
        "f128",
        "isize",
        "noreturn",
        "type",
        "usize",
        "void",
    ],
    constants: &["true", "false", "null", "undefined"],
    capitalized_types: true,
    calls: true,
    definitions: &[("fn", TokenKind::Function)],
    hook: Some(zig_words),
    ..Spec::EMPTY
};

/// `@builtin`s as macros, `@"quoted"` identifiers, `\\` multiline string
/// lines and the arbitrary-width integer types (`u7`, `i24`).
fn zig_words(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    let len = chars.len();
    match chars[i] {
        '\\' if cx.starts_with(i, "\\\\") => {
            cx.push(i, len, TokenKind::String);
            Some(len)
        }
        '@' => match chars.get(i + 1) {
            Some('"') => Some(string_end(chars, i + 1, '"')),
            Some(c) if c.is_alphabetic() || *c == '_' => {
                let end = ident_end(chars, i + 1);
                cx.push(i, end, TokenKind::Macro);
                Some(end)
            }
            _ => None,
        },
        'i' | 'u' if word_start(chars, i) => {
            let digits = scan_while(chars, i + 1, |c| c.is_ascii_digit());
            let whole = digits > i + 1 && ident_end(chars, i) == digits;
            whole.then(|| {
                cx.push(i, digits, TokenKind::Type);
                digits
            })
        }
        _ => None,
    }
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static ZIG: LanguageDef = LanguageDef {
    id: "zig",
    name: "Zig",
    extensions: &["zig", "zon"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
