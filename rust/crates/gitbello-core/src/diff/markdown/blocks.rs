//! Markdown blocks: headings (ATX and setext), paragraphs, fenced and
//! indented code, front matter, thematic breaks, blockquotes, bullet,
//! ordered and task lists, GFM tables, HTML blocks (read for their text) and
//! link reference definitions. Containers flatten into each leaf block's
//! `quote`, `indent` and `marker`. Close to CommonMark, not exact.

use super::inline::{decode_entities, normalize_label, parse_inline, Refs};
use super::{Align, Block, BlockKind, CodeLine, Content, ListMarker, Row, Span};

/// A block before its inline text is parsed (references can come later in
/// the document than the links that use them).
#[derive(Debug, Clone)]
enum Raw {
    Paragraph(String),
    Heading(u8, String),
    Code(String, Vec<String>),
    Table(Vec<Align>, Vec<Vec<String>>),
    Rule,
    /// An HTML block, read for its text; `Some(level)` for `<h1>`…`<h6>`.
    Html(Option<u8>, String),
}

#[derive(Debug, Clone)]
struct RawBlock {
    raw: Raw,
    quote: u8,
    indent: u8,
    marker: Option<ListMarker>,
}

#[derive(Clone, Copy)]
struct Ctx {
    quote: u8,
    indent: u8,
}

/// The blocks of a Markdown document.
pub fn parse(text: &str) -> Vec<Block> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines: Vec<String> = text.lines().map(expand_tabs).collect();
    let mut raws = Vec::new();
    let mut refs = Refs::new();
    if let Some(end) = front_matter_end(&lines) {
        raws.push(RawBlock {
            raw: Raw::Code("yaml".into(), lines[1..end].to_vec()),
            quote: 0,
            indent: 0,
            marker: None,
        });
        lines.drain(..=end);
    }
    parse_lines(
        &lines,
        Ctx {
            quote: 0,
            indent: 0,
        },
        &mut raws,
        &mut refs,
    );
    raws.into_iter()
        .filter_map(|raw| finish(raw, &refs))
        .collect()
}

/// `---` on the first line closed by `---` or `...`: YAML front matter.
fn front_matter_end(lines: &[String]) -> Option<usize> {
    if lines.first().map(|l| l.trim_end()) != Some("---") {
        return None;
    }
    lines
        .iter()
        .skip(1)
        .position(|l| matches!(l.trim_end(), "---" | "..."))
        .map(|i| i + 1)
}

fn expand_tabs(line: &str) -> String {
    if !line.contains('\t') {
        return line.trim_end_matches('\r').to_owned();
    }
    let mut out = String::with_capacity(line.len() + 8);
    let mut column = 0;
    for c in line.trim_end_matches('\r').chars() {
        if c == '\t' {
            let spaces = 4 - column % 4;
            out.extend(std::iter::repeat_n(' ', spaces));
            column += spaces;
        } else {
            out.push(c);
            column += 1;
        }
    }
    out
}

fn indent_of(line: &str) -> usize {
    line.bytes().take_while(|&b| b == b' ').count()
}

fn is_blank(line: &str) -> bool {
    line.trim().is_empty()
}

/// `line` without its first `n` columns of indentation (fewer if it has
/// fewer).
fn strip_indent(line: &str, n: usize) -> String {
    let have = indent_of(line).min(n);
    line[have..].to_owned()
}

fn parse_lines(lines: &[String], ctx: Ctx, out: &mut Vec<RawBlock>, refs: &mut Refs) {
    let mut para: Vec<String> = Vec::new();
    let push = |out: &mut Vec<RawBlock>, raw: Raw| {
        out.push(RawBlock {
            raw,
            quote: ctx.quote,
            indent: ctx.indent,
            marker: None,
        });
    };
    let flush = |para: &mut Vec<String>, out: &mut Vec<RawBlock>| {
        if !para.is_empty() {
            push(out, Raw::Paragraph(para.join("\n")));
            para.clear();
        }
    };
    let mut i = 0;
    while i < lines.len() {
        let line = &lines[i];
        let ind = indent_of(line);
        let trimmed = &line[ind..];
        if trimmed.trim().is_empty() {
            flush(&mut para, out);
            i += 1;
            continue;
        }
        if ind >= 4 {
            if para.is_empty() {
                let mut code = Vec::new();
                while i < lines.len() && (is_blank(&lines[i]) || indent_of(&lines[i]) >= 4) {
                    code.push(strip_indent(&lines[i], 4));
                    i += 1;
                }
                while code.last().is_some_and(|l| is_blank(l)) {
                    code.pop();
                }
                push(out, Raw::Code(String::new(), code));
            } else {
                para.push(trimmed.to_owned());
                i += 1;
            }
            continue;
        }
        if let Some((fence, len, info)) = fence_open(trimmed) {
            flush(&mut para, out);
            let mut code = Vec::new();
            i += 1;
            while i < lines.len() {
                if fence_closes(&lines[i], fence, len) {
                    i += 1;
                    break;
                }
                code.push(strip_indent(&lines[i], ind));
                i += 1;
            }
            push(out, Raw::Code(info, code));
            continue;
        }
        if let Some((level, text)) = atx_heading(trimmed) {
            flush(&mut para, out);
            push(out, Raw::Heading(level, text));
            i += 1;
            continue;
        }
        if !para.is_empty() {
            if let Some(level) = setext_level(trimmed) {
                push(out, Raw::Heading(level, para.join("\n")));
                para.clear();
                i += 1;
                continue;
            }
        }
        if is_rule(trimmed) {
            flush(&mut para, out);
            push(out, Raw::Rule);
            i += 1;
            continue;
        }
        if trimmed.starts_with('>') {
            flush(&mut para, out);
            let mut inner = Vec::new();
            let mut last_blank = false;
            while i < lines.len() {
                let l = &lines[i];
                let t = l.trim_start();
                if indent_of(l) < 4 && t.starts_with('>') {
                    let body = &t[1..];
                    let body = body.strip_prefix(' ').unwrap_or(body);
                    last_blank = is_blank(body);
                    inner.push(body.to_owned());
                } else if !is_blank(l) && !last_blank && !starts_block(l) && !inner.is_empty() {
                    // A lazy continuation of the quote's paragraph.
                    inner.push(t.to_owned());
                } else {
                    break;
                }
                i += 1;
            }
            parse_lines(
                &inner,
                Ctx {
                    quote: ctx.quote.saturating_add(1),
                    ..ctx
                },
                out,
                refs,
            );
            continue;
        }
        if let Some(item) = list_item(trimmed, ind) {
            if para.is_empty() || item.interrupts {
                flush(&mut para, out);
                i = parse_item(lines, i, &item, ctx, out, refs);
                continue;
            }
        }
        if para.is_empty() && html_start(trimmed) {
            let comment = trimmed.starts_with("<!--");
            let mut html = Vec::new();
            while i < lines.len() && !is_blank(&lines[i]) {
                html.push(lines[i].trim().to_owned());
                i += 1;
                if comment && html.last().is_some_and(|l| l.contains("-->")) {
                    break;
                }
            }
            if comment {
                // Comments may span blank lines: read on to their end.
                while !html.iter().any(|l| l.contains("-->")) && i < lines.len() {
                    html.push(lines[i].trim().to_owned());
                    i += 1;
                }
            }
            let joined = html.join("\n");
            push(out, Raw::Html(html_heading(&joined), joined));
            continue;
        }
        if para.is_empty() {
            if let Some((label, url)) = reference_definition(trimmed) {
                refs.entry(label).or_insert(url);
                i += 1;
                continue;
            }
        }
        if let Some(aligns) = lines
            .get(i + 1)
            .filter(|_| trimmed.contains('|'))
            .and_then(|next| delimiter_row(next))
        {
            let header = split_row(trimmed);
            if header.len() == aligns.len() {
                flush(&mut para, out);
                let mut rows = vec![header];
                i += 2;
                while i < lines.len() && !is_blank(&lines[i]) && !starts_block(&lines[i]) {
                    let mut row = split_row(lines[i].trim());
                    row.resize(aligns.len(), String::new());
                    rows.push(row);
                    i += 1;
                }
                push(out, Raw::Table(aligns, rows));
                continue;
            }
        }
        para.push(trimmed.to_owned());
        i += 1;
    }
    flush(&mut para, out);
}

/// Whether `line` starts a block that ends a paragraph or a table: a fence,
/// a heading, a rule, a quote or a list item.
fn starts_block(line: &str) -> bool {
    let ind = indent_of(line);
    if ind >= 4 {
        return false;
    }
    let t = &line[ind..];
    fence_open(t).is_some()
        || atx_heading(t).is_some()
        || is_rule(t)
        || t.starts_with('>')
        || list_item(t, ind).is_some_and(|item| item.interrupts)
}

/// A fence's character, length and info string.
fn fence_open(line: &str) -> Option<(char, usize, String)> {
    let c = line.chars().next().filter(|&c| c == '`' || c == '~')?;
    let len = line.chars().take_while(|&x| x == c).count();
    if len < 3 {
        return None;
    }
    let info = line[len..].trim();
    if c == '`' && info.contains('`') {
        return None;
    }
    let tag = info.split_whitespace().next().unwrap_or("");
    let tag = tag.trim_start_matches('{').trim_end_matches('}');
    Some((c, len, decode_entities(tag)))
}

fn fence_closes(line: &str, fence: char, len: usize) -> bool {
    let ind = indent_of(line);
    if ind >= 4 {
        return false;
    }
    let t = &line[ind..];
    let run = t.chars().take_while(|&x| x == fence).count();
    run >= len && t[run..].trim().is_empty()
}

fn atx_heading(line: &str) -> Option<(u8, String)> {
    let level = line.bytes().take_while(|&b| b == b'#').count();
    if level == 0 || level > 6 {
        return None;
    }
    let rest = &line[level..];
    if !rest.is_empty() && !rest.starts_with(' ') {
        return None;
    }
    let mut text = rest.trim();
    // A closing run of #s after a space.
    let without = text.trim_end_matches('#');
    if without.is_empty() || without.ends_with(' ') {
        text = without.trim_end();
    }
    Some((level as u8, text.to_owned()))
}

fn setext_level(line: &str) -> Option<u8> {
    let t = line.trim_end();
    if !t.is_empty() && t.bytes().all(|b| b == b'=') {
        Some(1)
    } else if !t.is_empty() && t.bytes().all(|b| b == b'-') {
        Some(2)
    } else {
        None
    }
}

fn is_rule(line: &str) -> bool {
    let Some(c) = line.chars().next().filter(|c| matches!(c, '-' | '*' | '_')) else {
        return false;
    };
    let mut count = 0;
    for x in line.chars() {
        if x == c {
            count += 1;
        } else if x != ' ' {
            return false;
        }
    }
    count >= 3
}

struct Item {
    marker: ListMarker,
    /// Columns before the item's content (where its continuation lines
    /// start).
    content: usize,
    /// Its first line's text after the marker.
    first: String,
    /// Whether it can interrupt a paragraph: not empty, and an ordered list
    /// only from 1.
    interrupts: bool,
}

/// A list item's marker at the start of `line` (`ind` columns in).
fn list_item(line: &str, ind: usize) -> Option<Item> {
    let bytes = line.as_bytes();
    let (marker, width) = match bytes.first()? {
        b'-' | b'*' | b'+' => (ListMarker::Bullet, 1),
        b'0'..=b'9' => {
            let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
            if digits > 9 || !matches!(bytes.get(digits), Some(b'.' | b')')) {
                return None;
            }
            (
                ListMarker::Ordered(line[..digits].parse().ok()?),
                digits + 1,
            )
        }
        _ => return None,
    };
    let rest = &line[width..];
    if !rest.is_empty() && !rest.starts_with(' ') {
        return None;
    }
    let spaces = indent_of(rest);
    let (offset, first) = if rest.trim().is_empty() {
        (1, String::new())
    } else if spaces > 4 {
        (1, rest[1..].to_owned())
    } else {
        (spaces, rest[spaces..].to_owned())
    };
    let interrupts =
        !first.trim().is_empty() && !matches!(marker, ListMarker::Ordered(n) if n != 1);
    Some(Item {
        marker,
        content: ind + width + offset,
        first,
        interrupts,
    })
}

/// Parses the list item starting at line `at` and returns the line after it.
fn parse_item(
    lines: &[String],
    at: usize,
    item: &Item,
    ctx: Ctx,
    out: &mut Vec<RawBlock>,
    refs: &mut Refs,
) -> usize {
    let mut inner = vec![item.first.clone()];
    let mut i = at + 1;
    while i < lines.len() {
        let line = &lines[i];
        if is_blank(line) {
            inner.push(String::new());
        } else if indent_of(line) >= item.content {
            inner.push(line[item.content..].to_owned());
        } else if !inner.last().is_some_and(|l| is_blank(l))
            && !starts_block(line)
            && list_item(line.trim_start(), indent_of(line)).is_none()
        {
            // A lazy continuation of the item's paragraph.
            inner.push(line.trim_start().to_owned());
        } else {
            break;
        }
        i += 1;
    }
    while inner.len() > 1 && inner.last().is_some_and(|l| is_blank(l)) {
        inner.pop();
        i -= 1;
    }
    // Blank lines after the item belong to no one.
    while i < lines.len() && is_blank(&lines[i]) {
        i += 1;
    }
    let first = out.len();
    let inner_ctx = Ctx {
        indent: ctx.indent.saturating_add(1),
        ..ctx
    };
    parse_lines(&inner, inner_ctx, out, refs);
    if out.len() == first {
        out.push(RawBlock {
            raw: Raw::Paragraph(String::new()),
            quote: ctx.quote,
            indent: inner_ctx.indent,
            marker: None,
        });
    }
    let block = &mut out[first];
    let mut marker = item.marker;
    if let Raw::Paragraph(text) = &mut block.raw {
        for (prefix, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] {
            if let Some(rest) = text.strip_prefix(prefix) {
                *text = rest.to_owned();
                marker = ListMarker::Task(done);
                break;
            }
        }
        if matches!(text.as_str(), "[ ]" | "[x]" | "[X]") {
            marker = ListMarker::Task(text != "[ ]");
            text.clear();
        }
    }
    block.marker = Some(marker);
    i
}

fn html_start(line: &str) -> bool {
    let mut chars = line.chars();
    chars.next() == Some('<')
        && chars
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '/' || c == '!')
}

/// `Some(level)` when an HTML block starts with `<h1>`…`<h6>`.
fn html_heading(html: &str) -> Option<u8> {
    let bytes = html.as_bytes();
    (bytes.len() > 3
        && bytes[0] == b'<'
        && bytes[1].eq_ignore_ascii_case(&b'h')
        && (b'1'..=b'6').contains(&bytes[2])
        && matches!(bytes[3], b'>' | b' '))
    .then(|| bytes[2] - b'0')
}

/// `[label]: url "title"`.
fn reference_definition(line: &str) -> Option<(String, String)> {
    let rest = line.strip_prefix('[')?;
    let close = rest.find("]:")?;
    let label = &rest[..close];
    if label.trim().is_empty() || label.contains('[') || label.contains(']') {
        return None;
    }
    let url = rest[close + 2..].split_whitespace().next()?;
    let url = url.trim_start_matches('<').trim_end_matches('>');
    Some((normalize_label(label), decode_entities(url)))
}

/// A table's delimiter row (`| :--- | ---: |`): each column's alignment.
fn delimiter_row(line: &str) -> Option<Vec<Align>> {
    let t = line.trim();
    if indent_of(line) >= 4 || !(t.contains('|') || t.contains('-')) {
        return None;
    }
    let cells = split_row(t);
    if cells.is_empty() {
        return None;
    }
    cells
        .iter()
        .map(|cell| {
            let left = cell.starts_with(':');
            let right = cell.ends_with(':');
            let dashes = cell.trim_matches(':');
            if dashes.is_empty() || !dashes.bytes().all(|b| b == b'-') {
                return None;
            }
            Some(match (left, right) {
                (true, true) => Align::Center,
                (true, false) => Align::Left,
                (false, true) => Align::Right,
                (false, false) => Align::None,
            })
        })
        .collect()
}

/// A table row's cells, trimmed, without the outer pipes; `\|` is a pipe and
/// pipes in code spans do not split.
fn split_row(line: &str) -> Vec<String> {
    let t = line.trim();
    let t = t.strip_prefix('|').unwrap_or(t);
    let t = if t.ends_with('|') && !t.ends_with("\\|") {
        &t[..t.len() - 1]
    } else {
        t
    };
    let mut cells = Vec::new();
    let mut cell = String::new();
    let mut in_code = false;
    let mut chars = t.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&'|') => {
                cell.push('|');
                chars.next();
            }
            '`' => {
                in_code = !in_code;
                cell.push(c);
            }
            '|' if !in_code => cells.push(std::mem::take(&mut cell).trim().to_owned()),
            _ => cell.push(c),
        }
    }
    cells.push(cell.trim().to_owned());
    cells
}

fn finish(raw: RawBlock, refs: &Refs) -> Option<Block> {
    let spans = |text: &str| parse_inline(text, refs);
    let (kind, content) = match raw.raw {
        Raw::Paragraph(text) => (BlockKind::Paragraph, Content::Text(spans(&text))),
        Raw::Heading(level, text) => (BlockKind::Heading(level), Content::Text(spans(&text))),
        Raw::Code(info, lines) => (
            BlockKind::Code,
            Content::Code {
                info,
                lines: lines
                    .into_iter()
                    .map(|text| CodeLine {
                        text,
                        change: super::Change::Same,
                    })
                    .collect(),
            },
        ),
        Raw::Table(aligns, rows) => (
            BlockKind::Table,
            Content::Table {
                aligns,
                rows: rows
                    .into_iter()
                    .map(|cells| Row {
                        cells: cells.iter().map(|c| spans(c)).collect(),
                        change: super::Change::Same,
                    })
                    .collect(),
            },
        ),
        Raw::Rule => (BlockKind::Rule, Content::None),
        Raw::Html(level, html) => {
            let text = spans(&html);
            // Tags alone (`<p align="center">`, comments) draw nothing.
            if text.iter().all(|s: &Span| s.text.trim().is_empty()) && raw.marker.is_none() {
                return None;
            }
            let kind = level.map_or(BlockKind::Paragraph, BlockKind::Heading);
            (kind, Content::Text(text))
        }
    };
    Some(Block {
        kind,
        quote: raw.quote,
        indent: raw.indent,
        marker: raw.marker,
        content,
    })
}

#[cfg(test)]
mod tests {
    use super::super::style;
    use super::*;

    /// `kind quote indent marker: text` per block.
    fn outline(text: &str) -> Vec<String> {
        parse(text)
            .iter()
            .map(|b| {
                let marker = match b.marker {
                    None => String::new(),
                    Some(ListMarker::Bullet) => " -".into(),
                    Some(ListMarker::Ordered(n)) => format!(" {n}."),
                    Some(ListMarker::Task(done)) => format!(" [{}]", if done { "x" } else { " " }),
                };
                let kind = match b.kind {
                    BlockKind::Heading(level) => format!("h{level}"),
                    other => other.id().to_owned(),
                };
                let body = match &b.content {
                    Content::Text(spans) => spans.iter().map(|s| s.text.as_str()).collect(),
                    Content::Code { info, lines } => format!(
                        "{info}|{}",
                        lines
                            .iter()
                            .map(|l| l.text.as_str())
                            .collect::<Vec<_>>()
                            .join("/")
                    ),
                    Content::Table { rows, .. } => rows
                        .iter()
                        .map(|r| {
                            r.cells
                                .iter()
                                .map(|c| c.iter().map(|s| s.text.as_str()).collect::<String>())
                                .collect::<Vec<_>>()
                                .join(",")
                        })
                        .collect::<Vec<_>>()
                        .join(";"),
                    Content::None => String::new(),
                };
                format!("{kind} {} {}{marker}: {body}", b.quote, b.indent)
            })
            .collect()
    }

    #[test]
    fn headings_paragraphs_and_rules() {
        assert_eq!(
            outline("# Title #\n\nOne\nline.\n\nSub\n---\n\n***\n\nBig\n===\n####### no"),
            vec![
                "h1 0 0: Title",
                "paragraph 0 0: One line.",
                "h2 0 0: Sub",
                "rule 0 0: ",
                "h1 0 0: Big",
                "paragraph 0 0: ####### no",
            ]
        );
        assert_eq!(outline("#tag"), vec!["paragraph 0 0: #tag"]);
    }

    #[test]
    fn code_blocks_and_front_matter() {
        assert_eq!(
            outline("---\ntitle: x\n---\n```rust\nfn a() {}\n\n```\n\n    indented\n    code\n\n~~~\nopen"),
            vec![
                "code 0 0: yaml|title: x",
                "code 0 0: rust|fn a() {}/",
                "code 0 0: |indented/code",
                "code 0 0: |open",
            ]
        );
        assert_eq!(
            outline("para\n    still para"),
            vec!["paragraph 0 0: para still para"]
        );
    }

    #[test]
    fn lists_nest_and_carry_markers() {
        assert_eq!(
            outline(
                "- one\n- two\n  - nested\n\n  more of two\n3. three\n- [x] done\n- [ ] todo\n"
            ),
            vec![
                "paragraph 0 1 -: one",
                "paragraph 0 1 -: two",
                "paragraph 0 2 -: nested",
                "paragraph 0 1: more of two",
                "paragraph 0 1 3.: three",
                "paragraph 0 1 [x]: done",
                "paragraph 0 1 [ ]: todo",
            ]
        );
        assert_eq!(
            outline("1. a\nlazy\n2) b\n\n   ```\n   code\n   ```"),
            vec![
                "paragraph 0 1 1.: a lazy",
                "paragraph 0 1 2.: b",
                "code 0 1: |code",
            ]
        );
        // An ordered list not starting at 1 does not interrupt a paragraph.
        assert_eq!(
            outline("Year\n2024. was"),
            vec!["paragraph 0 0: Year 2024. was"]
        );
        assert_eq!(
            outline("-\n- x"),
            vec!["paragraph 0 1 -: ", "paragraph 0 1 -: x"]
        );
    }

    #[test]
    fn quotes_nest_with_lazy_lines() {
        assert_eq!(
            outline("> quote\nlazy\n> > deeper\n>\n> - item\n\nout"),
            vec![
                "paragraph 1 0: quote lazy",
                "paragraph 2 0: deeper",
                "paragraph 1 1 -: item",
                "paragraph 0 0: out",
            ]
        );
    }

    #[test]
    fn tables() {
        let blocks = parse("| A | B |\n|:--|--:|\n| 1 | `a\\|b` |\n| 2 |\n\nafter");
        let Content::Table { aligns, rows } = &blocks[0].content else {
            panic!("not a table: {blocks:?}");
        };
        assert_eq!(aligns, &vec![Align::Left, Align::Right]);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[1].cells[1][0].text, "a|b");
        assert_eq!(rows[1].cells[1][0].style, style::CODE);
        assert!(rows[2].cells[1].is_empty());
        assert_eq!(outline("a | b\n--|--\nc | d"), vec!["table 0 0: a,b;c,d"]);
        assert_eq!(outline("a | b\n-- x\n"), vec!["paragraph 0 0: a | b -- x"]);
    }

    #[test]
    fn html_blocks_and_references() {
        assert_eq!(
            outline(
                "<p align=\"center\">\n  <img src=\"logo.png\" alt=\"Logo\">\n</p>\n\n<!-- note\n\nstill -->\n\n<h2 align=\"center\">Hi</h2>\n\n<div>\n\n[x]: https://x.dev\n[See][x]"
            ),
            vec!["paragraph 0 0: Logo", "h2 0 0: Hi", "paragraph 0 0: See"]
        );
        let blocks = parse("[a]\n\n[a]: https://later.dev");
        let Content::Text(spans) = &blocks[0].content else {
            panic!();
        };
        assert_eq!(spans[0].link.as_deref(), Some("https://later.dev"));
    }

    #[test]
    fn tabs_crlf_and_bom() {
        assert_eq!(
            outline("\u{feff}# T\r\n\r\n-\tx\r\n\tcode? no, lazy\r\n"),
            vec!["h1 0 0: T", "paragraph 0 1 -: x code? no, lazy"]
        );
    }
}
