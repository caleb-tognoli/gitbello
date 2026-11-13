use super::super::generic::{Escape, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::{ident_end, scan_while, string_end};
use super::{no_hints, LanguageDef};

/// Parameters (`@p`, `@@identity`, `:p`, `$1`) as variables, and quoted
/// identifiers (`"order"`, `` `order` ``, `[order]`) left plain so the
/// words inside are not keywords.
fn sql_words(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    match chars[i] {
        '"' | '`' => Some(string_end(chars, i, chars[i])),
        '[' if chars
            .get(i + 1)
            .is_some_and(|c| c.is_alphabetic() || *c == '_') =>
        {
            let close = (i + 1..chars.len()).find(|&j| chars[j] == ']')?;
            chars[i + 1..close]
                .iter()
                .all(|c| c.is_alphanumeric() || " _".contains(*c))
                .then_some(close + 1)
        }
        '@' => {
            let name = scan_while(chars, i, |c| c == '@');
            let end = ident_end(chars, name);
            (end > name).then(|| {
                cx.push(i, end, TokenKind::Variable);
                end
            })
        }
        ':' if i == 0 || chars[i - 1] != ':' => {
            let end = ident_end(chars, i + 1);
            let named = chars.get(i + 1).is_some_and(|c| c.is_alphabetic());
            (named && cx.at(end) != Some(':')).then(|| {
                cx.push(i, end, TokenKind::Variable);
                end
            })
        }
        '$' if chars.get(i + 1).is_some_and(char::is_ascii_digit) => {
            let end = scan_while(chars, i + 1, |c| c.is_ascii_digit());
            cx.push(i, end, TokenKind::Variable);
            Some(end)
        }
        _ => None,
    }
}

static SPEC: Spec = Spec {
    line_comments: &["--"],
    block_comment: Some(("/*", "*/")),
    strings: &[
        Str::lines("E'", "'", BACKSLASH),
        Str::lines("e'", "'", BACKSLASH),
        Str::lines("N'", "'", Escape::Doubled),
        Str::lines("n'", "'", Escape::Doubled),
        Str::lines("'", "'", Escape::Doubled),
    ],
    keywords: &[
        "add",
        "all",
        "alter",
        "and",
        "any",
        "as",
        "asc",
        "begin",
        "between",
        "by",
        "cascade",
        "check",
        "collate",
        "column",
        "commit",
        "constraint",
        "create",
        "cross",
        "database",
        "declare",
        "default",
        "delete",
        "desc",
        "distinct",
        "drop",
        "exec",
        "execute",
        "exists",
        "foreign",
        "from",
        "full",
        "function",
        "grant",
        "group",
        "having",
        "ilike",
        "in",
        "index",
        "inner",
        "insert",
        "intersect",
        "into",
        "is",
        "join",
        "key",
        "language",
        "left",
        "like",
        "limit",
        "materialized",
        "natural",
        "not",
        "offset",
        "on",
        "or",
        "order",
        "outer",
        "over",
        "partition",
        "primary",
        "procedure",
        "recursive",
        "references",
        "replace",
        "restrict",
        "returning",
        "returns",
        "revoke",
        "right",
        "rollback",
        "schema",
        "select",
        "set",
        "table",
        "temp",
        "temporary",
        "transaction",
        "trigger",
        "truncate",
        "union",
        "unique",
        "update",
        "using",
        "values",
        "view",
        "where",
        "window",
        "with",
    ],
    control_keywords: &[
        "case", "else", "elsif", "end", "if", "loop", "return", "then", "when", "while",
    ],
    types: &[
        "bigint",
        "bigserial",
        "binary",
        "bit",
        "blob",
        "bool",
        "boolean",
        "bytea",
        "char",
        "date",
        "datetime",
        "datetime2",
        "decimal",
        "double",
        "float",
        "int",
        "integer",
        "interval",
        "json",
        "jsonb",
        "money",
        "nchar",
        "numeric",
        "nvarchar",
        "precision",
        "real",
        "serial",
        "smallint",
        "text",
        "time",
        "timestamp",
        "timestamptz",
        "tinyint",
        "uuid",
        "varbinary",
        "varchar",
        "xml",
    ],
    constants: &["null", "true", "false"],
    case_insensitive: true,
    calls: true,
    hook: Some(sql_words),
    ..Spec::EMPTY
};

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static SQL: LanguageDef = LanguageDef {
    id: "sql",
    name: "SQL",
    extensions: &["sql", "ddl"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
