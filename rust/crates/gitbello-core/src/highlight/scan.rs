//! Scanners shared by the lexers. Each takes the line's characters and a
//! start index and returns where the construct ends (exclusive).

/// A character that can continue an identifier.
pub fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// The first index from `from` where `keep` fails (or the end).
pub fn scan_while(chars: &[char], from: usize, keep: impl Fn(char) -> bool) -> usize {
    (from..chars.len())
        .find(|&j| !keep(chars[j]))
        .unwrap_or(chars.len())
}

/// True when `i` starts a word: the line start or after a non-identifier.
pub fn word_start(chars: &[char], i: usize) -> bool {
    i == 0 || !is_ident(chars[i - 1])
}

/// The end of the identifier starting at `start`.
pub fn ident_end(chars: &[char], start: usize) -> usize {
    scan_while(chars, start, is_ident)
}

/// The end of the string opened by `quote` at `start`, skipping
/// backslash escapes; the end of the line when it is not closed.
pub fn string_end(chars: &[char], start: usize, quote: char) -> usize {
    let mut j = start + 1;
    while j < chars.len() {
        if chars[j] == '\\' {
            j += 2;
            continue;
        }
        if chars[j] == quote {
            return j + 1;
        }
        j += 1;
    }
    chars.len()
}

/// The end of the number starting at `start` (a digit): letters, digits and
/// `_` (prefixes, suffixes, exponents, separators), and a `.` only when a
/// digit follows, so `0..10` keeps its range operator.
pub fn number_end(chars: &[char], start: usize) -> usize {
    let hex = chars.get(start) == Some(&'0') && matches!(chars.get(start + 1), Some('x' | 'X'));
    let mut j = start;
    while j < chars.len() {
        let c = chars[j];
        let fraction = c == '.' && chars.get(j + 1).is_some_and(char::is_ascii_digit);
        // A signed exponent: `1.5e-3` (not in hex, where `0x1E-3` subtracts).
        let exponent_sign = matches!(c, '+' | '-')
            && !hex
            && j > start
            && matches!(chars[j - 1], 'e' | 'E')
            && chars[j - 2..j - 1].iter().all(char::is_ascii_digit)
            && chars.get(j + 1).is_some_and(char::is_ascii_digit);
        // A digit separator: `1'000'000` (C++, C23).
        let separator = c == '\''
            && j > start
            && chars[j - 1].is_ascii_alphanumeric()
            && chars.get(j + 1).is_some_and(char::is_ascii_digit)
            && chars.get(j + 2) != Some(&'\'');
        if c.is_alphanumeric() || c == '_' || fraction || exponent_sign || separator {
            j += 1;
        } else {
            break;
        }
    }
    j
}

/// The end of `close` searched from `from`, past it; the line end when
/// missing.
pub fn find_end(chars: &[char], from: usize, close: &str) -> usize {
    let close: Vec<char> = close.chars().collect();
    (from..chars.len())
        .find(|&j| chars[j..].starts_with(&close))
        .map_or(chars.len(), |j| j + close.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chars(s: &str) -> Vec<char> {
        s.chars().collect()
    }

    #[test]
    fn numbers_strings_and_ends() {
        let c = chars("0..10 1.5e3 0x1F_u8 3.");
        assert_eq!(number_end(&c, 0), 1);
        assert_eq!(number_end(&c, 3), 5);
        assert_eq!(number_end(&c, 6), 11);
        assert_eq!(number_end(&c, 12), 19);
        assert_eq!(number_end(&c, 20), 21);
        assert_eq!(number_end(&chars("1.5e-3)"), 0), 6);
        assert_eq!(number_end(&chars("2E+10"), 0), 5);
        assert_eq!(number_end(&chars("0x1E-3"), 0), 4);
        assert_eq!(number_end(&chars("1-2"), 0), 1);
        assert_eq!(number_end(&chars("1'000'000;"), 0), 9);
        assert_eq!(number_end(&chars("f(1,'2')"), 2), 3);
        let s = chars(r#""a\"b" x"#);
        assert_eq!(string_end(&s, 0, '"'), 6);
        assert_eq!(string_end(&chars("\"open"), 0, '"'), 5);
        assert_eq!(string_end(&chars("\"\\"), 0, '"'), 2);
        assert_eq!(find_end(&chars("/* a */ b"), 2, "*/"), 7);
        assert_eq!(find_end(&chars("/* a"), 2, "*/"), 4);
        assert!(word_start(&chars("a b"), 2));
        assert!(!word_start(&chars("ab"), 1));
    }
}
