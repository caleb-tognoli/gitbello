use super::super::kind::TokenKind;
use super::super::lexer::{language_tag, Cx, Lexer};
use super::super::scan::scan_while;
use super::css;
use super::{no_hints, Language, LanguageDef};

/// HTML and XML: tag names as tags, attribute names as attributes and
/// their values as strings (plain in XML, where they are most of a file
/// such as an SVG's path data), comments, `<!DOCTYPE …>` and `<?xml …?>` with
/// their names as keywords, CDATA sections as code and entities as
/// escapes. Comments, CDATA sections, tags and quoted values go on across
/// lines; lexed without the state above, a line that starts with `name=`
/// continues a tag. In HTML, `<script>` and `<style>` elements are lexed as
/// JavaScript (JSON for a JSON `type`, plain for other types) or CSS, also
/// across lines, `style="…"` as CSS declarations and `on…="…"` as
/// JavaScript.
pub(super) struct MarkupLexer {
    pub(super) html: bool,
}

/// A character of a tag or attribute name (`svg:path`, `data-x`, `v-on:click`,
/// `[value]`, `(click)`, `@click`, `#ref`, `*ngIf`).
fn name_char(c: char) -> bool {
    !c.is_whitespace() && !matches!(c, '=' | '>' | '/' | '"' | '\'' | '<')
}

/// [`Cx::state`] values: what a line left open, in the low four bits, and
/// the element whose tag or body it is ([`Element`]) above them.
mod state {
    pub const COMMENT: u16 = 1;
    pub const CDATA: u16 = 2;
    /// Inside a tag, among its attributes.
    pub const TAG: u16 = 3;
    /// Inside a tag, in a value quoted with `"` or `'`.
    pub const VALUE_DOUBLE: u16 = 4;
    pub const VALUE_SINGLE: u16 = 5;
    /// In the body of a `<script>` or `<style>` element.
    pub const BODY: u16 = 6;
    pub const MODE: u16 = 0xF;
    pub const ELEMENT_SHIFT: u16 = 4;
}

/// True when HTML left in `state` stands among a tag's attributes (where
/// Razor reads `@onclick` as one).
pub(super) fn in_tag(state: u16) -> bool {
    state & state::MODE == state::TAG
}

/// An element whose body is another language.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Element {
    None,
    Script,
    Json,
    /// A script of another type (a template): plain.
    PlainScript,
    Style,
}

impl Element {
    fn bits(self) -> u16 {
        let n = match self {
            Self::None => 0,
            Self::Script => 1,
            Self::Json => 2,
            Self::PlainScript => 3,
            Self::Style => 4,
        };
        n << state::ELEMENT_SHIFT
    }

    fn of(state: u16) -> Self {
        match state >> state::ELEMENT_SHIFT {
            1 => Self::Script,
            2 => Self::Json,
            3 => Self::PlainScript,
            4 => Self::Style,
            _ => Self::None,
        }
    }

    /// The tag that ends the body.
    fn close(self) -> &'static str {
        if self == Self::Style {
            "</style"
        } else {
            "</script"
        }
    }

    /// The language of the body; `None` for a plain body.
    fn language(self) -> Option<Language> {
        match self {
            Self::Script => Language::by_id("javascript"),
            Self::Json => Language::by_id("json"),
            Self::Style => Language::by_id("css"),
            Self::None | Self::PlainScript => None,
        }
    }
}

impl Lexer for MarkupLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let chars = cx.chars();
        let len = chars.len();
        let incoming = cx.state();
        let element = Element::of(incoming);
        cx.set_state(0);
        let mut i = match incoming & state::MODE {
            0 => {
                let at = scan_while(chars, cx.pos, char::is_whitespace);
                if continues_tag(chars, at) {
                    self.attributes(cx, at).0
                } else {
                    at
                }
            }
            state::COMMENT => close_or_keep(cx, cx.pos, cx.pos, "-->", incoming),
            state::CDATA => {
                let close = (cx.pos..len).find(|&j| cx.starts_with(j, "]]>"));
                cx.push(cx.pos, close.unwrap_or(len), TokenKind::MarkupCode);
                match close {
                    Some(c) => {
                        cx.push(c, c + 3, TokenKind::Keyword);
                        c + 3
                    }
                    None => {
                        cx.set_state(incoming);
                        len
                    }
                }
            }
            state::VALUE_DOUBLE | state::VALUE_SINGLE => {
                let quote = if incoming & state::MODE == state::VALUE_DOUBLE {
                    '"'
                } else {
                    '\''
                };
                match (cx.pos..len).find(|&j| chars[j] == quote) {
                    Some(c) => {
                        self.push_value(cx, cx.pos, c + 1);
                        self.rest_of_tag(cx, c + 1, element)
                    }
                    None => {
                        self.push_value(cx, cx.pos, len);
                        cx.set_state(incoming);
                        len
                    }
                }
            }
            state::BODY => self.body(cx, cx.pos, element, true),
            _ => self.rest_of_tag(cx, cx.pos, element),
        };
        cx.pos = len;
        while i < len {
            let c = chars[i];
            if c == '<' {
                i = self.markup(cx, i);
            } else if c == '&' {
                let end = entity_end(chars, i);
                cx.push(i, end, TokenKind::StringEscape);
                i = end.max(i + 1);
            } else {
                // Text up to the next tag or entity stays plain.
                i = (i + 1..len)
                    .find(|&j| matches!(chars[j], '<' | '&'))
                    .unwrap_or(len);
            }
        }
    }
}

/// Pushes a comment from `from` to past the first `close` at or after
/// `search`; when `close` is not on the line, to its end, and the next line
/// goes on in `state`.
fn close_or_keep(cx: &mut Cx<'_>, from: usize, search: usize, close: &str, state: u16) -> usize {
    let len = cx.len();
    let at = (search..len).find(|&j| cx.starts_with(j, close));
    let end = at.map_or(len, |j| j + close.chars().count());
    cx.push(from, end, TokenKind::Comment);
    if at.is_none() {
        cx.set_state(state);
    }
    end
}

/// True when the line at `i` goes on with a tag's attributes (`id="x">`,
/// `/>`).
fn continues_tag(chars: &[char], i: usize) -> bool {
    if chars[i..].starts_with(&['/', '>']) {
        return true;
    }
    let name = scan_while(chars, i, name_char);
    name > i && chars.get(name) == Some(&'=') && matches!(chars.get(name + 1), Some('"' | '\''))
}

/// The end of the entity at `i` (`&amp;`, `&#38;`, `&#x26;`), or `i` when
/// none starts there.
fn entity_end(chars: &[char], i: usize) -> usize {
    let body = if chars.get(i + 1) == Some(&'#') {
        i + 2
    } else {
        i + 1
    };
    let end = scan_while(chars, body, |c| c.is_ascii_alphanumeric());
    if end > body && end - body <= 32 && chars.get(end) == Some(&';') {
        end + 1
    } else {
        i
    }
}

/// The element a `<script>` tag opens, by its `type` attribute in
/// `attributes` (lowercase).
fn script_element(attributes: &str) -> Element {
    let Some(at) = attributes.find("type=") else {
        return Element::Script;
    };
    let value: String = attributes[at + 5..]
        .trim_start_matches(['"', '\''])
        .chars()
        .take_while(|c| !matches!(c, '"' | '\'' | ' ' | '>'))
        .collect();
    if value.is_empty()
        || value == "module"
        || value.contains("javascript")
        || value.contains("ecmascript")
        || value.contains("babel")
        || value.contains("jsx")
    {
        Element::Script
    } else if value.contains("json") {
        Element::Json
    } else {
        Element::PlainScript
    }
}

impl MarkupLexer {
    /// Whatever starts with `<` at `i`; returns where it ends.
    fn markup(&self, cx: &mut Cx<'_>, i: usize) -> usize {
        let chars = cx.chars();
        let len = chars.len();
        if cx.starts_with(i, "<!--") {
            return close_or_keep(cx, i, i + 4, "-->", state::COMMENT);
        }
        if cx.starts_with(i, "<![CDATA[") {
            cx.push(i, i + 9, TokenKind::Keyword);
            let close = (i + 9..len).find(|&j| cx.starts_with(j, "]]>"));
            cx.push(i + 9, close.unwrap_or(len), TokenKind::MarkupCode);
            return match close {
                Some(c) => {
                    cx.push(c, c + 3, TokenKind::Keyword);
                    c + 3
                }
                None => {
                    cx.set_state(state::CDATA);
                    len
                }
            };
        }
        // `<!DOCTYPE html>`, `<?xml version="1.0"?>`.
        if matches!(cx.at(i + 1), Some('!' | '?')) {
            let name_end = scan_while(chars, i + 2, name_char);
            cx.push(i, i + 2, TokenKind::Punctuation);
            cx.push(i + 2, name_end, TokenKind::Keyword);
            return self.attributes(cx, name_end).0;
        }
        let closing = cx.at(i + 1) == Some('/');
        let name = if closing { i + 2 } else { i + 1 };
        if !cx.at(name).is_some_and(|c| c.is_alphabetic() || c == '_') {
            return i + 1;
        }
        let name_end = scan_while(chars, name, name_char);
        cx.push(i, name, TokenKind::Punctuation);
        cx.push(name, name_end, TokenKind::Tag);
        let tag: String = chars[name..name_end]
            .iter()
            .collect::<String>()
            .to_lowercase();
        let element = match tag.as_str() {
            _ if !self.html || closing => Element::None,
            "script" => {
                // The type, when it is on this line.
                let rest: String = chars[name_end..]
                    .iter()
                    .take_while(|&&c| c != '>')
                    .collect::<String>()
                    .to_lowercase();
                script_element(&rest)
            }
            "style" => Element::Style,
            _ => Element::None,
        };
        self.rest_of_tag(cx, name_end, element)
    }

    /// A tag's attributes from `from` to its `>`, then the body of
    /// `element` when the tag opens one. A tag that goes on past the line
    /// keeps `element` in its state.
    fn rest_of_tag(&self, cx: &mut Cx<'_>, from: usize, element: Element) -> usize {
        let (end, self_closing) = self.attributes(cx, from);
        let mode = cx.state() & state::MODE;
        if mode == state::TAG || mode == state::VALUE_DOUBLE || mode == state::VALUE_SINGLE {
            cx.set_state(mode | element.bits());
            return end;
        }
        if element == Element::None || self_closing {
            return end;
        }
        self.body(cx, end, element, false)
    }

    /// The body of `element` from `from` to its closing tag (or the line
    /// end, when the next line goes on in it); with `resume`, it goes on
    /// from the state the line above left.
    fn body(&self, cx: &mut Cx<'_>, from: usize, element: Element, resume: bool) -> usize {
        let chars = cx.chars();
        let len = chars.len();
        let close = element.close();
        let end = (from..len)
            .find(|&j| starts_with_lower(chars, j, close))
            .unwrap_or(len);
        if let Some(language) = element.language() {
            cx.embed_open(language_tag(language), language.lexer(), from, end, resume);
        }
        if end == len {
            cx.set_state(state::BODY | element.bits());
        } else {
            cx.set_nested(None);
        }
        end
    }

    /// A tag's attributes from `from` to its `>` (or the line end): where
    /// they end, and whether the tag closed itself (`/>`).
    fn attributes(&self, cx: &mut Cx<'_>, from: usize) -> (usize, bool) {
        let chars = cx.chars();
        let len = chars.len();
        let mut j = from;
        let mut name = (0, 0);
        while j < len {
            let c = chars[j];
            if c.is_whitespace() {
                j += 1;
            } else if c == '>' {
                cx.push(j, j + 1, TokenKind::Punctuation);
                return (j + 1, false);
            } else if matches!(c, '/' | '?') && cx.at(j + 1) == Some('>') {
                cx.push(j, j + 2, TokenKind::Punctuation);
                return (j + 2, c == '/');
            } else if c == '=' {
                cx.push(j, j + 1, TokenKind::Operator);
                j = self.value(cx, j + 1, &chars[name.0..name.1]);
            } else if c == '"' || c == '\'' {
                j = self.value(cx, j, &[]);
            } else if name_char(c) {
                let end = scan_while(chars, j, name_char);
                cx.push(j, end, TokenKind::Attribute);
                name = (j, end);
                j = end;
            } else {
                j += 1;
            }
        }
        // The tag goes on on the next line (unless a value left its own
        // state).
        if cx.state() == 0 {
            cx.set_state(state::TAG);
        }
        (len, false)
    }

    /// The value after `=` at `from` of attribute `name`: quoted or bare, a
    /// string, or CSS or JavaScript in HTML's `style` and `on…`.
    fn value(&self, cx: &mut Cx<'_>, from: usize, name: &[char]) -> usize {
        let chars = cx.chars();
        let len = chars.len();
        let at = scan_while(chars, from, char::is_whitespace);
        let Some(quote) = cx.at(at).filter(|&q| q == '"' || q == '\'') else {
            let end = scan_while(chars, at, |c| !c.is_whitespace() && c != '>');
            self.push_value(cx, at, end);
            return end;
        };
        let close = (at + 1..len).find(|&k| chars[k] == quote);
        let end = close.map_or(len, |c| c + 1);
        if close.is_none() {
            cx.set_state(if quote == '"' {
                state::VALUE_DOUBLE
            } else {
                state::VALUE_SINGLE
            });
        }
        let lower: String = name.iter().collect::<String>().to_lowercase();
        let script = self.html && lower.len() > 2 && lower.starts_with("on");
        if !(self.html && lower == "style") && !script {
            self.push_value(cx, at, end);
            return end;
        }
        cx.push(at, at + 1, TokenKind::String);
        let body_end = close.unwrap_or(len);
        if script {
            if let Some(js) = Language::by_id("javascript") {
                cx.embed(js, at + 1, body_end);
            }
        } else {
            cx.embed_with(&css::DECLARATIONS, at + 1, body_end);
        }
        cx.push(body_end, end, TokenKind::String);
        end
    }

    /// An attribute's value `[start, end)`: a string in HTML, plain in XML.
    fn push_value(&self, cx: &mut Cx<'_>, start: usize, end: usize) {
        if self.html {
            cx.push(start, end, TokenKind::String);
        }
    }
}

/// True when `s` (lowercase) starts at `i`, ignoring case.
fn starts_with_lower(chars: &[char], i: usize, s: &str) -> bool {
    (i..)
        .zip(s.chars())
        .all(|(j, c)| chars.get(j).is_some_and(|ch| ch.to_ascii_lowercase() == c))
}

pub static HTML: LanguageDef = LanguageDef {
    id: "html",
    name: "HTML",
    extensions: &["html", "htm", "xhtml"],
    file_names: &[],
    shebangs: &[],
    lexer: &MarkupLexer { html: true },
    hints: no_hints,
};

pub static XML: LanguageDef = LanguageDef {
    id: "xml",
    name: "XML",
    extensions: &[
        "xml",
        "svg",
        "xsd",
        "xsl",
        "xslt",
        "csproj",
        "vbproj",
        "fsproj",
        "vcxproj",
        "props",
        "targets",
        "plist",
        "xaml",
        "axaml",
        "resx",
        "nuspec",
        "wxs",
        "storyboard",
        "xib",
        "rss",
        "atom",
        "kml",
        "gpx",
        "manifest",
    ],
    file_names: &[],
    shebangs: &[],
    lexer: &MarkupLexer { html: false },
    hints: no_hints,
};
