//! Just enough JSON to read the avatar URL out of GitHub's and GitLab's
//! answers (no serde_json: a few lookups do not need a crate).

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    pub fn parse(text: &str) -> Option<Json> {
        let mut parser = Parser {
            bytes: text.as_bytes(),
            at: 0,
            depth: 0,
        };
        let value = parser.value()?;
        parser.space();
        (parser.at == parser.bytes.len()).then_some(value)
    }

    /// The value of `key` in an object.
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// The value at `path` of keys in nested objects.
    pub fn at(&self, path: &[&str]) -> Option<&Json> {
        path.iter().try_fold(self, |value, key| value.get(key))
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(text) => Some(text),
            _ => None,
        }
    }
}

/// Nesting deeper than this is not an API answer we read.
const MAX_DEPTH: usize = 64;

struct Parser<'a> {
    bytes: &'a [u8],
    at: usize,
    depth: usize,
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn space(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn eat(&mut self, byte: u8) -> bool {
        self.space();
        if self.peek() == Some(byte) {
            self.at += 1;
            true
        } else {
            false
        }
    }

    fn literal(&mut self, word: &str, value: Json) -> Option<Json> {
        let end = self.at + word.len();
        (self.bytes.get(self.at..end)? == word.as_bytes()).then(|| {
            self.at = end;
            value
        })
    }

    fn value(&mut self) -> Option<Json> {
        self.space();
        match self.peek()? {
            b'{' => self.nested(Self::object),
            b'[' => self.nested(Self::array),
            b'"' => self.string().map(Json::String),
            b't' => self.literal("true", Json::Bool(true)),
            b'f' => self.literal("false", Json::Bool(false)),
            b'n' => self.literal("null", Json::Null),
            _ => self.number(),
        }
    }

    fn nested(&mut self, parse: fn(&mut Self) -> Option<Json>) -> Option<Json> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return None;
        }
        let value = parse(self);
        self.depth -= 1;
        value
    }

    fn object(&mut self) -> Option<Json> {
        self.at += 1;
        let mut fields = Vec::new();
        if self.eat(b'}') {
            return Some(Json::Object(fields));
        }
        loop {
            self.space();
            let key = self.string()?;
            if !self.eat(b':') {
                return None;
            }
            fields.push((key, self.value()?));
            if self.eat(b'}') {
                return Some(Json::Object(fields));
            }
            if !self.eat(b',') {
                return None;
            }
        }
    }

    fn array(&mut self) -> Option<Json> {
        self.at += 1;
        let mut items = Vec::new();
        if self.eat(b']') {
            return Some(Json::Array(items));
        }
        loop {
            items.push(self.value()?);
            if self.eat(b']') {
                return Some(Json::Array(items));
            }
            if !self.eat(b',') {
                return None;
            }
        }
    }

    fn number(&mut self) -> Option<Json> {
        let start = self.at;
        while matches!(
            self.peek(),
            Some(b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E')
        ) {
            self.at += 1;
        }
        let text = std::str::from_utf8(&self.bytes[start..self.at]).ok()?;
        text.parse().ok().map(Json::Number)
    }

    fn string(&mut self) -> Option<String> {
        if self.peek()? != b'"' {
            return None;
        }
        self.at += 1;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let byte = self.peek()?;
            self.at += 1;
            match byte {
                b'"' => return String::from_utf8(out).ok(),
                b'\\' => {
                    let escape = self.peek()?;
                    self.at += 1;
                    let ch = match escape {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => self.unicode()?,
                        _ => return None,
                    };
                    let mut buf = [0u8; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                }
                _ => out.push(byte),
            }
        }
    }

    /// The character of a `\u` escape (after `\u`), surrogate pairs joined.
    fn unicode(&mut self) -> Option<char> {
        let first = self.hex4()?;
        if (0xD800..0xDC00).contains(&first) {
            if self.bytes.get(self.at..self.at + 2)? != b"\\u" {
                return None;
            }
            self.at += 2;
            let second = self.hex4()?;
            if !(0xDC00..0xE000).contains(&second) {
                return None;
            }
            return char::from_u32(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00));
        }
        char::from_u32(first)
    }

    fn hex4(&mut self) -> Option<u32> {
        let digits = std::str::from_utf8(self.bytes.get(self.at..self.at + 4)?).ok()?;
        self.at += 4;
        u32::from_str_radix(digits, 16).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_nested_values() {
        let json = Json::parse(
            r#"{"sha": "abc", "commit": {"author": {"email": "a@b.c"}},
                "author": {"login": "octo", "id": 1, "site_admin": false,
                           "avatar_url": "https:\/\/avatars.example\/u\/1?v=4"},
                "parents": [{"sha": "d"}, null, 1.5e2, true]}"#,
        )
        .unwrap();
        assert_eq!(
            json.at(&["commit", "author", "email"])
                .and_then(Json::as_str),
            Some("a@b.c")
        );
        assert_eq!(
            json.at(&["author", "avatar_url"]).and_then(Json::as_str),
            Some("https://avatars.example/u/1?v=4")
        );
        assert_eq!(json.at(&["author", "id"]), Some(&Json::Number(1.0)));
        assert_eq!(
            json.get("parents"),
            Some(&Json::Array(vec![
                Json::Object(vec![("sha".into(), Json::String("d".into()))]),
                Json::Null,
                Json::Number(150.0),
                Json::Bool(true),
            ]))
        );
        assert!(json.at(&["author", "missing"]).is_none());
    }

    #[test]
    fn reads_escapes_and_non_ascii() {
        let json = Json::parse(r#"["tab\there", "ü 😀", "ü"]"#).unwrap();
        assert_eq!(
            json,
            Json::Array(vec![
                Json::String("tab\there".into()),
                Json::String("ü 😀".into()),
                Json::String("ü".into()),
            ])
        );
    }

    #[test]
    fn rejects_broken_input() {
        for text in [
            "",
            "{",
            r#"{"a" 1}"#,
            "[1,]",
            r#""open"#,
            "nul",
            "{} x",
            r#""\x""#,
        ] {
            assert!(Json::parse(text).is_none(), "{text:?}");
        }
        let deep = "[".repeat(MAX_DEPTH + 1) + &"]".repeat(MAX_DEPTH + 1);
        assert!(Json::parse(&deep).is_none());
    }
}
