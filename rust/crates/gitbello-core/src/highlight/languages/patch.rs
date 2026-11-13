use super::super::kind::TokenKind;
use super::super::lexer::{Cx, Lexer};
use super::{no_hints, LanguageDef};

/// Lines of a patch that are headers whole.
const HEADERS: &[&str] = &[
    "diff ",
    "index ",
    "--- ",
    "+++ ",
    "new file mode",
    "deleted file mode",
    "old mode",
    "new mode",
    "similarity index",
    "dissimilarity index",
    "rename from",
    "rename to",
    "copy from",
    "copy to",
    "Binary files",
    "GIT binary patch",
    "Only in ",
    "Index: ",
    "=====",
];

/// Mail headers of a `git format-patch` file.
const MAIL: &[&str] = &["From:", "Date:", "Subject:", "To:", "Cc:"];

/// Diffs and patches: file and hunk headers as `diff.header` (a hunk's
/// function context after `@@` stays plain), added and removed lines as
/// `diff.added` and `diff.removed`, `\ No newline…` as a comment and
/// `format-patch` mail headers as keys.
struct PatchLexer;

impl Lexer for PatchLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let len = cx.len();
        let i = cx.pos;
        cx.pos = len;
        if HEADERS.iter().any(|h| cx.starts_with(i, h)) || from_line(cx, i) {
            cx.push(i, len, TokenKind::DiffHeader);
            return;
        }
        if cx.starts_with(i, "@@") {
            let chars = cx.chars();
            let close = (i + 2..len)
                .find(|&j| cx.starts_with(j, "@@"))
                .map_or(len, |j| (j..len).find(|&k| chars[k] != '@').unwrap_or(len));
            cx.push(i, close, TokenKind::DiffHeader);
            return;
        }
        if let Some(name) = MAIL.iter().find(|m| cx.starts_with(i, m)) {
            cx.push(i, i + name.len() - 1, TokenKind::Key);
            return;
        }
        match cx.at(i) {
            Some('+') => cx.push(i, len, TokenKind::DiffAdded),
            Some('-') if !cx.starts_with(i, "---") || len - i > 3 => {
                cx.push(i, len, TokenKind::DiffRemoved)
            }
            Some('\\') => cx.push(i, len, TokenKind::Comment),
            _ => {}
        }
    }
}

/// `From <40 hex digits> <date>`: the first line of a `format-patch` mail.
fn from_line(cx: &Cx<'_>, i: usize) -> bool {
    cx.starts_with(i, "From ")
        && (i + 5..i + 45).all(|j| cx.at(j).is_some_and(|c| c.is_ascii_hexdigit()))
}

pub static PATCH: LanguageDef = LanguageDef {
    id: "diff",
    name: "Diff",
    extensions: &["diff", "patch", "rej"],
    file_names: &[],
    shebangs: &[],
    lexer: &PatchLexer,
    hints: no_hints,
};
