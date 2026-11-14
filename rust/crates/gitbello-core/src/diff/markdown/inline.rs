//! Inline Markdown: emphasis, strong, strikethrough, code spans, links,
//! images, autolinks and bare URLs, escapes, entities, line breaks and the
//! few inline HTML tags that matter for reading (`<br>`, `<img>`, the rest
//! dropped). Close to CommonMark and GFM, not exact: brackets match by
//! nesting depth and emphasis follows the delimiter-run rules.

use std::collections::HashMap;

use super::{style, Span};

/// Link reference definitions by normalized label (see [`normalize_label`]).
pub type Refs = HashMap<String, String>;

/// Lower-cased with runs of whitespace as one space, as labels compare.
pub fn normalize_label(label: &str) -> String {
    label
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

#[derive(Debug, Clone)]
enum Node {
    Text(String),
    Code(String),
    Break,
    Delim {
        ch: char,
        count: usize,
        open: bool,
        close: bool,
    },
    Styled(u8, Vec<Node>),
    Link(String, Vec<Node>),
    Image(String, String),
}

/// The spans of `text` (a paragraph's lines joined by `\n`).
pub fn parse_inline(text: &str, refs: &Refs) -> Vec<Span> {
    let chars: Vec<char> = text.trim().chars().collect();
    let nodes = parse_nodes(&chars, refs);
    let mut spans = Vec::new();
    flatten(&nodes, 0, None, &mut spans);
    // Dropped tags can leave whitespace at either end.
    if let Some(first) = spans.first_mut() {
        first.text = first.text.trim_start().to_owned();
    }
    if let Some(last) = spans.last_mut() {
        last.text = last.text.trim_end().to_owned();
    }
    spans.retain(|s| !s.text.is_empty());
    spans
}

fn parse_nodes(chars: &[char], refs: &Refs) -> Vec<Node> {
    let mut nodes = Vec::new();
    let mut text = String::new();
    let mut i = 0;
    let flush = |text: &mut String, nodes: &mut Vec<Node>| {
        if !text.is_empty() {
            nodes.push(Node::Text(std::mem::take(text)));
        }
    };
    while i < chars.len() {
        let c = chars[i];
        match c {
            '\\' if i + 1 < chars.len() && chars[i + 1] == '\n' => {
                flush(&mut text, &mut nodes);
                nodes.push(Node::Break);
                i += 2;
                i = skip_spaces(chars, i);
            }
            '\\' if i + 1 < chars.len() && chars[i + 1].is_ascii_punctuation() => {
                text.push(chars[i + 1]);
                i += 2;
            }
            '\n' => {
                let hard = text.ends_with("  ");
                let kept = text.trim_end_matches(' ').len();
                text.truncate(kept);
                if hard {
                    flush(&mut text, &mut nodes);
                    nodes.push(Node::Break);
                } else {
                    text.push(' ');
                }
                i = skip_spaces(chars, i + 1);
            }
            '`' => {
                let run = run_length(chars, i, '`');
                if let Some(end) = find_backtick_run(chars, i + run, run) {
                    flush(&mut text, &mut nodes);
                    let code: String = chars[i + run..end]
                        .iter()
                        .map(|&c| if c == '\n' { ' ' } else { c })
                        .collect();
                    let stripped = if code.len() >= 2
                        && code.starts_with(' ')
                        && code.ends_with(' ')
                        && !code.trim().is_empty()
                    {
                        code[1..code.len() - 1].to_owned()
                    } else {
                        code
                    };
                    nodes.push(Node::Code(stripped));
                    i = end + run;
                } else {
                    text.extend(std::iter::repeat_n('`', run));
                    i += run;
                }
            }
            '*' | '_' | '~' => {
                let run = run_length(chars, i, c);
                if c == '~' && run > 2 {
                    text.extend(std::iter::repeat_n('~', run));
                    i += run;
                    continue;
                }
                flush(&mut text, &mut nodes);
                let before = if i == 0 { ' ' } else { chars[i - 1] };
                let after = chars.get(i + run).copied().unwrap_or(' ');
                let (open, close) = flanking(c, before, after);
                nodes.push(Node::Delim {
                    ch: c,
                    count: run,
                    open,
                    close,
                });
                i += run;
            }
            '!' if chars.get(i + 1) == Some(&'[') => {
                if let Some((node, end)) = link_at(chars, i + 1, refs, true) {
                    flush(&mut text, &mut nodes);
                    nodes.push(node);
                    i = end;
                } else {
                    text.push('!');
                    i += 1;
                }
            }
            '[' => {
                if let Some((node, end)) = link_at(chars, i, refs, false) {
                    flush(&mut text, &mut nodes);
                    nodes.push(node);
                    i = end;
                } else {
                    text.push('[');
                    i += 1;
                }
            }
            '<' => {
                if let Some((node, end)) = angle_at(chars, i) {
                    flush(&mut text, &mut nodes);
                    if let Some(node) = node {
                        nodes.push(node);
                    }
                    i = end;
                } else {
                    text.push('<');
                    i += 1;
                }
            }
            '&' => {
                if let Some((decoded, end)) = entity_at(chars, i) {
                    text.push_str(&decoded);
                    i = end;
                } else {
                    text.push('&');
                    i += 1;
                }
            }
            'h' | 'w' if word_start(chars, i) => {
                if let Some(end) = bare_url_end(chars, i) {
                    flush(&mut text, &mut nodes);
                    let url: String = chars[i..end].iter().collect();
                    let target = if url.starts_with("www.") {
                        format!("http://{url}")
                    } else {
                        url.clone()
                    };
                    nodes.push(Node::Link(target, vec![Node::Text(url)]));
                    i = end;
                } else {
                    text.push(c);
                    i += 1;
                }
            }
            _ => {
                text.push(c);
                i += 1;
            }
        }
    }
    flush(&mut text, &mut nodes);
    emphasis(&mut nodes);
    nodes
}

fn skip_spaces(chars: &[char], mut i: usize) -> usize {
    while i < chars.len() && chars[i] == ' ' {
        i += 1;
    }
    i
}

fn run_length(chars: &[char], at: usize, c: char) -> usize {
    chars[at..].iter().take_while(|&&x| x == c).count()
}

fn find_backtick_run(chars: &[char], from: usize, run: usize) -> Option<usize> {
    let mut i = from;
    while i < chars.len() {
        if chars[i] == '`' {
            let len = run_length(chars, i, '`');
            if len == run {
                return Some(i);
            }
            i += len;
        } else {
            i += 1;
        }
    }
    None
}

fn is_punct(c: char) -> bool {
    c.is_ascii_punctuation() || (!c.is_alphanumeric() && !c.is_whitespace())
}

/// Whether a delimiter run between `before` and `after` can open and close
/// emphasis (CommonMark's left- and right-flanking rules).
fn flanking(c: char, before: char, after: char) -> (bool, bool) {
    let left =
        !after.is_whitespace() && (!is_punct(after) || before.is_whitespace() || is_punct(before));
    let right =
        !before.is_whitespace() && (!is_punct(before) || after.is_whitespace() || is_punct(after));
    if c == '_' {
        (
            left && (!right || is_punct(before)),
            right && (!left || is_punct(after)),
        )
    } else {
        (left, right)
    }
}

/// Matches emphasis delimiters, innermost closers first, wrapping what lies
/// between an opener and its closer.
fn emphasis(nodes: &mut Vec<Node>) {
    let mut i = 0;
    while i < nodes.len() {
        let Node::Delim {
            ch,
            count,
            close: true,
            open: closer_opens,
        } = nodes[i]
        else {
            i += 1;
            continue;
        };
        if count == 0 {
            i += 1;
            continue;
        }
        let mut found = None;
        for j in (0..i).rev() {
            if let Node::Delim {
                ch: c,
                count: n,
                open: true,
                close: opener_closes,
            } = nodes[j]
            {
                if c != ch || n == 0 {
                    continue;
                }
                if c == '~' && n != count {
                    continue;
                }
                // The rule of three.
                if (opener_closes || closer_opens)
                    && (n + count) % 3 == 0
                    && !(n % 3 == 0 && count % 3 == 0)
                {
                    continue;
                }
                found = Some((j, n));
                break;
            }
        }
        let Some((j, opener_count)) = found else {
            i += 1;
            continue;
        };
        let used = if ch == '~' {
            count
        } else if count >= 2 && opener_count >= 2 {
            2
        } else {
            1
        };
        let bits = match (ch, used) {
            ('~', _) => style::STRIKE,
            (_, 2) => style::STRONG,
            _ => style::EMPHASIS,
        };
        let inner: Vec<Node> = nodes.drain(j + 1..i).collect();
        if let Node::Delim { count, .. } = &mut nodes[j] {
            *count -= used;
        }
        if let Node::Delim { count, .. } = &mut nodes[j + 1] {
            *count -= used;
        }
        nodes.insert(j + 1, Node::Styled(bits, inner));
        // The closer is now at j + 2 and may close again.
        i = j + 2;
    }
}

/// A link or image starting with the `[` at `at`: `[text](url "title")`,
/// `[text][label]`, `[label][]` or `[label]`, and where it ends.
fn link_at(chars: &[char], at: usize, refs: &Refs, image: bool) -> Option<(Node, usize)> {
    let close = matching_bracket(chars, at)?;
    let inner = &chars[at + 1..close];
    let mut end = close + 1;
    let url = if chars.get(end) == Some(&'(') {
        let (url, after) = inline_destination(chars, end + 1)?;
        end = after;
        url
    } else if chars.get(end) == Some(&'[') {
        let label_end = chars[end + 1..].iter().position(|&c| c == ']')? + end + 1;
        let label: String = chars[end + 1..label_end].iter().collect();
        let label = if label.trim().is_empty() {
            inner.iter().collect()
        } else {
            label
        };
        end = label_end + 1;
        refs.get(&normalize_label(&label))?.clone()
    } else {
        let label: String = inner.iter().collect();
        refs.get(&normalize_label(&label))?.clone()
    };
    let children = parse_nodes(inner, refs);
    if image {
        let mut alt = Vec::new();
        flatten(&children, 0, None, &mut alt);
        let alt: String = alt.iter().map(|s| s.text.as_str()).collect();
        return Some((Node::Image(alt, url), end));
    }
    Some((Node::Link(url, children), end))
}

/// The `]` closing the `[` at `at`, skipping escapes and code spans.
fn matching_bracket(chars: &[char], at: usize) -> Option<usize> {
    let mut depth = 0;
    let mut i = at;
    while i < chars.len() {
        match chars[i] {
            '\\' => i += 1,
            '`' => {
                let run = run_length(chars, i, '`');
                if let Some(end) = find_backtick_run(chars, i + run, run) {
                    i = end + run - 1;
                } else {
                    i += run - 1;
                }
            }
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// `url "title")` from just after the `(`: the url and the index after `)`.
fn inline_destination(chars: &[char], from: usize) -> Option<(String, usize)> {
    let mut i = skip_whitespace(chars, from);
    let mut url = String::new();
    if chars.get(i) == Some(&'<') {
        i += 1;
        while i < chars.len() && chars[i] != '>' {
            if chars[i] == '\n' {
                return None;
            }
            url.push(chars[i]);
            i += 1;
        }
        i += 1;
    } else {
        let mut depth = 0;
        while i < chars.len() {
            let c = chars[i];
            if c.is_whitespace() {
                break;
            }
            if c == '\\' && i + 1 < chars.len() && chars[i + 1].is_ascii_punctuation() {
                url.push(chars[i + 1]);
                i += 2;
                continue;
            }
            if c == '(' {
                depth += 1;
            } else if c == ')' {
                if depth == 0 {
                    break;
                }
                depth -= 1;
            }
            url.push(c);
            i += 1;
        }
    }
    i = skip_whitespace(chars, i);
    // An optional title.
    if let Some(&quote) = chars.get(i).filter(|c| matches!(c, '"' | '\'' | '(')) {
        let closer = if quote == '(' { ')' } else { quote };
        i += 1;
        while i < chars.len() && chars[i] != closer {
            i += if chars[i] == '\\' { 2 } else { 1 };
        }
        i += 1;
        i = skip_whitespace(chars, i);
    }
    (chars.get(i) == Some(&')')).then_some((url, i + 1))
}

fn skip_whitespace(chars: &[char], mut i: usize) -> usize {
    while i < chars.len() && chars[i].is_whitespace() {
        i += 1;
    }
    i
}

/// What starts at the `<` at `at`: an autolink, a `<br>` (a break), an
/// `<img>` (an image), another tag or a comment (dropped: `None`), and where
/// it ends.
fn angle_at(chars: &[char], at: usize) -> Option<(Option<Node>, usize)> {
    let rest: String = chars[at..chars.len().min(at + 4096)].iter().collect();
    if let Some(body) = rest.strip_prefix("<!--") {
        let end = body.find("-->")?;
        return Some((None, at + 4 + body[..end].chars().count() + 3));
    }
    let close = rest.find('>')?;
    let inside = &rest[1..close];
    let end = at + rest[..=close].chars().count();
    if inside.is_empty() || (inside.contains('\n') && !inside.starts_with(char::is_alphabetic)) {
        return None;
    }
    // Autolinks: <scheme:...> and <user@host>.
    if !inside.contains(char::is_whitespace) {
        if let Some((scheme, _)) = inside.split_once(':') {
            if scheme.len() >= 2
                && scheme
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c))
            {
                return Some((
                    Some(Node::Link(
                        inside.to_owned(),
                        vec![Node::Text(inside.to_owned())],
                    )),
                    end,
                ));
            }
        }
        if inside.contains('@') && !inside.starts_with('/') && inside.contains('.') {
            return Some((
                Some(Node::Link(
                    format!("mailto:{inside}"),
                    vec![Node::Text(inside.to_owned())],
                )),
                end,
            ));
        }
    }
    let name: String = inside
        .trim_start_matches('/')
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric())
        .collect();
    if name.is_empty()
        || !inside
            .trim_start_matches('/')
            .starts_with(char::is_alphabetic)
    {
        return None;
    }
    match name.to_ascii_lowercase().as_str() {
        "br" => Some((Some(Node::Break), end)),
        "img" => {
            let alt = attribute(inside, "alt").unwrap_or_default();
            let src = attribute(inside, "src").unwrap_or_default();
            Some((Some(Node::Image(alt, src)), end))
        }
        _ => Some((None, end)),
    }
}

/// The value of attribute `name` in a tag's inside (`img src="a.png"`).
pub fn attribute(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let mut from = 0;
    while let Some(found) = lower[from..].find(name) {
        let at = from + found;
        from = at + name.len();
        let before_ok = at == 0 || lower.as_bytes()[at - 1].is_ascii_whitespace();
        let rest = tag[from..].trim_start();
        if !before_ok || !rest.starts_with('=') {
            continue;
        }
        let value = rest[1..].trim_start();
        let (quote, body) = match value.chars().next()? {
            q @ ('"' | '\'') => (Some(q), &value[1..]),
            _ => (None, value),
        };
        let end = match quote {
            Some(q) => body.find(q)?,
            None => body
                .find(|c: char| c.is_whitespace() || c == '>' || c == '/')
                .unwrap_or(body.len()),
        };
        return Some(decode_entities(&body[..end]));
    }
    None
}

/// `text` with its entities decoded.
pub fn decode_entities(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '&' {
            if let Some((decoded, end)) = entity_at(&chars, i) {
                out.push_str(&decoded);
                i = end;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// A named or numeric entity at `at` and where it ends.
fn entity_at(chars: &[char], at: usize) -> Option<(String, usize)> {
    let end = chars[at..chars.len().min(at + 34)]
        .iter()
        .position(|&c| c == ';')?
        + at;
    let name: String = chars[at + 1..end].iter().collect();
    let decoded = if let Some(number) = name.strip_prefix('#') {
        let code = match number.strip_prefix(['x', 'X']) {
            Some(hex) => u32::from_str_radix(hex, 16).ok()?,
            None => number.parse().ok()?,
        };
        char::from_u32(code).unwrap_or('\u{FFFD}').to_string()
    } else {
        let c = match name.as_str() {
            "amp" => "&",
            "lt" => "<",
            "gt" => ">",
            "quot" => "\"",
            "apos" => "'",
            "nbsp" => "\u{a0}",
            "copy" => "©",
            "reg" => "®",
            "trade" => "™",
            "mdash" => "—",
            "ndash" => "–",
            "hellip" => "…",
            "laquo" => "«",
            "raquo" => "»",
            "middot" => "·",
            "times" => "×",
            "rarr" => "→",
            "larr" => "←",
            "check" => "✓",
            _ => return None,
        };
        c.to_owned()
    };
    Some((decoded, end + 1))
}

fn word_start(chars: &[char], i: usize) -> bool {
    i == 0 || {
        let before = chars[i - 1];
        before.is_whitespace() || matches!(before, '(' | '*' | '_' | '~' | '"' | '\'')
    }
}

/// The end of a bare `http://`, `https://` or `www.` URL at `at`, trailing
/// punctuation and unbalanced `)` left out.
fn bare_url_end(chars: &[char], at: usize) -> Option<usize> {
    let rest: String = chars[at..chars.len().min(at + 8)].iter().collect();
    let prefix = ["https://", "http://", "www."]
        .into_iter()
        .find(|p| rest.starts_with(p))?;
    let mut end = at;
    while end < chars.len() && !chars[end].is_whitespace() && chars[end] != '<' {
        end += 1;
    }
    loop {
        let last = chars[end - 1];
        if matches!(
            last,
            '.' | ',' | ':' | ';' | '!' | '?' | '"' | '\'' | '*' | '_' | '~'
        ) {
            end -= 1;
        } else if last == ')' {
            let opens = chars[at..end].iter().filter(|&&c| c == '(').count();
            let closes = chars[at..end].iter().filter(|&&c| c == ')').count();
            if closes > opens {
                end -= 1;
            } else {
                break;
            }
        } else {
            break;
        }
        if end <= at {
            return None;
        }
    }
    (end - at > prefix.chars().count()).then_some(end)
}

/// Appends `nodes` as spans in `bits` style and `link`, joining neighbours
/// that look the same.
fn flatten(nodes: &[Node], bits: u8, link: Option<&str>, out: &mut Vec<Span>) {
    let push = |text: &str, bits: u8, link: Option<&str>, out: &mut Vec<Span>| {
        if text.is_empty() {
            return;
        }
        if let Some(last) = out.last_mut() {
            if last.style == bits && last.link.as_deref() == link {
                last.text.push_str(text);
                return;
            }
        }
        out.push(Span {
            text: text.to_owned(),
            style: bits,
            link: link.map(str::to_owned),
            ..Span::default()
        });
    };
    for node in nodes {
        match node {
            Node::Text(text) => push(text, bits, link, out),
            Node::Code(code) => push(code, bits | style::CODE, link, out),
            Node::Break => push("\n", bits & !style::CODE, link, out),
            Node::Delim { ch, count, .. } => {
                push(&ch.to_string().repeat(*count), bits, link, out);
            }
            Node::Styled(more, inner) => flatten(inner, bits | more, link, out),
            Node::Link(url, inner) => flatten(inner, bits | style::LINK, Some(url), out),
            Node::Image(alt, src) => {
                let text = if alt.is_empty() {
                    src.rsplit('/').next().unwrap_or("image").to_owned()
                } else {
                    alt.clone()
                };
                push(&text, bits | style::IMAGE, Some(src), out);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spans(text: &str) -> Vec<(String, u8, Option<String>)> {
        let mut refs = Refs::new();
        refs.insert("docs".into(), "https://example.com/docs".into());
        parse_inline(text, &refs)
            .into_iter()
            .map(|s| (s.text, s.style, s.link))
            .collect()
    }

    fn plain(text: &str, bits: u8) -> (String, u8, Option<String>) {
        (text.to_owned(), bits, None)
    }

    #[test]
    fn emphasis_strong_and_strike() {
        assert_eq!(
            spans("a *b* __c__ ~~d~~ e"),
            vec![
                plain("a ", 0),
                plain("b", style::EMPHASIS),
                plain(" ", 0),
                plain("c", style::STRONG),
                plain(" ", 0),
                plain("d", style::STRIKE),
                plain(" e", 0),
            ]
        );
        assert_eq!(
            spans("***both***"),
            vec![plain("both", style::STRONG | style::EMPHASIS)]
        );
        assert_eq!(
            spans("**bold *and italic***"),
            vec![
                plain("bold ", style::STRONG),
                plain("and italic", style::STRONG | style::EMPHASIS)
            ]
        );
    }

    #[test]
    fn delimiters_that_do_not_flank_stay_text() {
        assert_eq!(spans("snake_case_name"), vec![plain("snake_case_name", 0)]);
        assert_eq!(spans("2 * 3 * 4"), vec![plain("2 * 3 * 4", 0)]);
        assert_eq!(spans("*open"), vec![plain("*open", 0)]);
        assert_eq!(spans("a ~~~ b"), vec![plain("a ~~~ b", 0)]);
    }

    #[test]
    fn code_spans_keep_their_text() {
        assert_eq!(
            spans("use `*x*` and `` a`b ``"),
            vec![
                plain("use ", 0),
                plain("*x*", style::CODE),
                plain(" and ", 0),
                plain("a`b", style::CODE),
            ]
        );
        assert_eq!(spans("`unclosed"), vec![plain("`unclosed", 0)]);
    }

    #[test]
    fn links_images_and_references() {
        assert_eq!(
            spans("see [the *docs*](https://x.dev \"Title\")"),
            vec![
                plain("see ", 0),
                ("the ".into(), style::LINK, Some("https://x.dev".into())),
                (
                    "docs".into(),
                    style::LINK | style::EMPHASIS,
                    Some("https://x.dev".into())
                ),
            ]
        );
        assert_eq!(
            spans("![logo](img/logo.png)"),
            vec![("logo".into(), style::IMAGE, Some("img/logo.png".into()))]
        );
        assert_eq!(
            spans("[Docs] and [here][docs]"),
            vec![
                (
                    "Docs".into(),
                    style::LINK,
                    Some("https://example.com/docs".into())
                ),
                plain(" and ", 0),
                (
                    "here".into(),
                    style::LINK,
                    Some("https://example.com/docs".into())
                ),
            ]
        );
        assert_eq!(spans("[not a link]"), vec![plain("[not a link]", 0)]);
        assert_eq!(spans("[a](b"), vec![plain("[a](b", 0)]);
    }

    #[test]
    fn autolinks_and_bare_urls() {
        assert_eq!(
            spans("<https://a.b/c> or https://x.y/z."),
            vec![
                (
                    "https://a.b/c".into(),
                    style::LINK,
                    Some("https://a.b/c".into())
                ),
                plain(" or ", 0),
                (
                    "https://x.y/z".into(),
                    style::LINK,
                    Some("https://x.y/z".into())
                ),
                plain(".", 0),
            ]
        );
        assert_eq!(
            spans("(www.site.org)"),
            vec![
                plain("(", 0),
                (
                    "www.site.org".into(),
                    style::LINK,
                    Some("http://www.site.org".into())
                ),
                plain(")", 0),
            ]
        );
    }

    #[test]
    fn html_breaks_entities_and_escapes() {
        assert_eq!(
            spans("a<br>b <span>c</span> &amp; &#169; \\*d\\*"),
            vec![plain("a\nb c & © *d*", 0)]
        );
        assert_eq!(
            spans("x <img src=\"a/b.png\" alt=\"Shot\"> <!-- hidden --> y"),
            vec![
                plain("x ", 0),
                ("Shot".into(), style::IMAGE, Some("a/b.png".into())),
                plain("  y", 0),
            ]
        );
        assert_eq!(spans("a < b > c"), vec![plain("a < b > c", 0)]);
    }

    #[test]
    fn line_breaks() {
        assert_eq!(spans("one\ntwo"), vec![plain("one two", 0)]);
        assert_eq!(spans("one  \ntwo"), vec![plain("one\ntwo", 0)]);
        assert_eq!(spans("one\\\ntwo"), vec![plain("one\ntwo", 0)]);
    }
}
