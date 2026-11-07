//! `Co-authored-by:` trailers (M7.10): the co-authors shown beside a commit's
//! author in the history rows and the commit details.

/// The trailer key, matched without case as git does.
pub const COAUTHOR_KEY: &str = "Co-authored-by";

/// Name and email of a trailer value `Name <email>`. A value without an
/// address is all name; one that is only `<email>` has an empty name.
pub fn parse_identity(value: &str) -> (&str, &str) {
    let value = value.trim();
    if let Some(open) = value.rfind('<') {
        if let Some(email) = value[open + 1..].strip_suffix('>') {
            return (value[..open].trim(), email.trim());
        }
    }
    (value, "")
}

/// The co-authors of a commit: its trailer values in order, without blanks,
/// repeats (by email, or by name when there is none) and the author.
pub fn distinct_coauthors<'a>(
    values: impl IntoIterator<Item = &'a str>,
    author_email: &str,
) -> Vec<(&'a str, &'a str)> {
    let mut out: Vec<(&str, &str)> = Vec::new();
    for value in values {
        let (name, email) = parse_identity(value);
        if name.is_empty() && email.is_empty() {
            continue;
        }
        let same = |a: &str, b: &str| a.eq_ignore_ascii_case(b);
        if !email.is_empty() && same(email, author_email) {
            continue;
        }
        let seen = out.iter().any(|&(n, e)| {
            if email.is_empty() && e.is_empty() {
                n == name
            } else {
                same(e, email)
            }
        });
        if !seen {
            out.push((name, email));
        }
    }
    out
}

/// The `Co-authored-by:` values in a full commit message: the lines of its
/// last paragraph (git's trailer block) that start with the key.
pub fn coauthor_values(message: &str) -> Vec<&str> {
    let lines: Vec<&str> = message.trim_end().lines().collect();
    // The subject alone has no trailers.
    let Some(blank) = lines.iter().rposition(|line| line.trim().is_empty()) else {
        return Vec::new();
    };
    lines[blank + 1..]
        .iter()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.trim()
                .eq_ignore_ascii_case(COAUTHOR_KEY)
                .then_some(value)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_names_and_addresses() {
        assert_eq!(
            parse_identity(" Ada Lovelace <ada@example.com> "),
            ("Ada Lovelace", "ada@example.com")
        );
        assert_eq!(parse_identity("Jérôme <j@ex.fr>"), ("Jérôme", "j@ex.fr"));
        assert_eq!(parse_identity("<bot@example.com>"), ("", "bot@example.com"));
        assert_eq!(parse_identity("Just A Name"), ("Just A Name", ""));
        assert_eq!(parse_identity("Odd <x"), ("Odd <x", ""));
    }

    #[test]
    fn drops_blanks_repeats_and_the_author() {
        let values = [
            "Ada <ADA@example.com>",
            "Ada Again <ada@example.com>",
            "",
            "Me <me@example.com>",
            "Bob",
            "Bob",
            "Carol <carol@example.com>",
        ];
        assert_eq!(
            distinct_coauthors(values, "me@EXAMPLE.com"),
            vec![
                ("Ada", "ADA@example.com"),
                ("Bob", ""),
                ("Carol", "carol@example.com")
            ]
        );
    }

    #[test]
    fn reads_trailers_from_the_last_paragraph_only() {
        let message = "Fix it\n\nCo-authored-by: Not <a@trailer>\nbody\n\nSigned-off-by: Me <me@x>\nco-authored-by: Ada <ada@x>\nCo-Authored-By:Bob <bob@x>\n";
        assert_eq!(
            coauthor_values(message),
            vec![" Ada <ada@x>", "Bob <bob@x>"]
        );
        assert_eq!(
            coauthor_values("Fix\r\n\r\nCo-authored-by: Ada <ada@x>\r\n"),
            vec![" Ada <ada@x>"]
        );
        assert!(coauthor_values("Subject only").is_empty());
        assert!(coauthor_values("Subject\n\nCo-authored-by is mentioned here").is_empty());
    }
}
