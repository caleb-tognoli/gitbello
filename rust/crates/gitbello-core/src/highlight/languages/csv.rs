use super::super::hints::{sniff_delimiter, FileHints};
use super::super::kind::TokenKind;
use super::super::lexer::{Cx, Lexer};
use super::LanguageDef;

/// Delimiter-separated values: field `i` as `column.(i % 8)` and the
/// delimiters as punctuation. The delimiter comes from the file's hints
/// (a comma when none was found); a delimiter inside double quotes belongs
/// to its field. A quoted field goes on across lines (the state is
/// `1 + field`, the field it is in); lexed without the state above, a line
/// starts a new row.
struct CsvLexer;

impl Lexer for CsvLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let delimiter = cx.hints().delimiter.unwrap_or(',');
        let chars = cx.chars();
        let len = chars.len();
        let mut i = cx.pos;
        cx.pos = len;
        // A quoted field from the line above goes on.
        let mut field = usize::from(cx.state().saturating_sub(1));
        let mut quoted = cx.state() != 0;
        cx.set_state(0);
        while i <= len {
            let mut j = i;
            while j < len {
                let c = chars[j];
                if c == '"' {
                    quoted = !quoted;
                } else if c == delimiter && !quoted {
                    break;
                }
                j += 1;
            }
            cx.push(i, j, TokenKind::COLUMNS[field % TokenKind::COLUMNS.len()]);
            if j >= len {
                if quoted {
                    cx.set_state(u16::try_from(field + 1).unwrap_or(u16::MAX));
                }
                break;
            }
            quoted = false;
            cx.push(j, j + 1, TokenKind::Punctuation);
            i = j + 1;
            field += 1;
        }
    }
}

fn sniffed(lines: &[String]) -> FileHints {
    FileHints {
        delimiter: sniff_delimiter(lines),
    }
}

fn tabs(_lines: &[String]) -> FileHints {
    FileHints {
        delimiter: Some('\t'),
    }
}

pub static CSV: LanguageDef = LanguageDef {
    id: "csv",
    name: "CSV",
    extensions: &["csv"],
    file_names: &[],
    shebangs: &[],
    lexer: &CsvLexer,
    hints: sniffed,
};

pub static TSV: LanguageDef = LanguageDef {
    id: "tsv",
    name: "TSV",
    extensions: &["tsv", "tab"],
    file_names: &[],
    shebangs: &[],
    lexer: &CsvLexer,
    hints: tabs,
};
