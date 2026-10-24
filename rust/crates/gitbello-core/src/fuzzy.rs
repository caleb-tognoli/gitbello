//! Fuzzy matching for the command palette.

/// Scores `candidate` against `query` (case-insensitive subsequence match).
/// Higher is better; `None` if not every query character appears in order.
/// Consecutive matches, matches at word starts and an early first match score higher.
pub fn score(query: &str, candidate: &str) -> Option<i32> {
    let query: Vec<char> = query
        .chars()
        .filter(|c| !c.is_whitespace())
        .flat_map(char::to_lowercase)
        .collect();
    if query.is_empty() {
        return Some(0);
    }
    let chars: Vec<char> = candidate.chars().collect();
    // Greedy matching from the leftmost occurrence can miss a better match
    // later on ("tab" in "Next Tab"), so try every start of the first char.
    (0..chars.len())
        .filter(|&i| chars[i].to_lowercase().eq(std::iter::once(query[0])))
        .filter_map(|start| score_from(&query, &chars, start))
        .max()
}

fn score_from(query: &[char], chars: &[char], start: usize) -> Option<i32> {
    let mut total = 0;
    let mut next = 0;
    let mut previous: Option<usize> = None;
    let mut first: Option<usize> = None;
    for (i, &c) in chars.iter().enumerate().skip(start) {
        if next == query.len() {
            break;
        }
        if !c.to_lowercase().eq(std::iter::once(query[next])) {
            continue;
        }
        let mut points = 1;
        if previous.is_some_and(|p| p + 1 == i) {
            points += 5;
        }
        let at_word_start = i == 0
            || chars
                .get(i - 1)
                .is_some_and(|p| !p.is_alphanumeric() || (p.is_lowercase() && c.is_uppercase()));
        if at_word_start {
            points += 8;
        }
        total += points;
        first.get_or_insert(i);
        previous = Some(i);
        next += 1;
    }
    if next < query.len() {
        return None;
    }
    let start_penalty = i32::try_from(first.unwrap_or(0) / 2)
        .unwrap_or(i32::MAX)
        .min(10);
    let length_penalty = i32::try_from(chars.len() / 8).unwrap_or(i32::MAX).min(10);
    Some(total - start_penalty - length_penalty)
}

/// Indices of `candidates` matching `query`, best first; ties keep input order.
pub fn rank<S: AsRef<str>>(query: &str, candidates: &[S]) -> Vec<usize> {
    let mut scored: Vec<(i32, usize)> = candidates
        .iter()
        .enumerate()
        .filter_map(|(i, c)| score(query, c.as_ref()).map(|s| (s, i)))
        .collect();
    scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    scored.into_iter().map(|(_, i)| i).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_subsequences_case_insensitively() {
        assert!(score("opr", "Open Repository").is_some());
        assert!(score("OPEN", "open repository").is_some());
        assert!(score("xyz", "Open Repository").is_none());
        assert!(score("ro", "or").is_none(), "order matters");
        assert_eq!(score("", "anything"), Some(0));
        assert_eq!(score("  ", "anything"), Some(0));
    }

    #[test]
    fn prefers_word_starts_and_consecutive_runs() {
        let ranked = rank(
            "tab",
            &[
                "Settings: Table Layout",
                "Close Tab",
                "Next Tab",
                "stabilize",
            ],
        );
        assert_eq!(ranked.len(), 4);
        // Word-start matches beat the mid-word one.
        assert_eq!(*ranked.last().unwrap(), 3);
        let ranked = rank("ct", &["Copy Text", "Close Tab", "ACTION"]);
        assert_eq!(&ranked[..2], &[0, 1], "ties keep input order");
        assert!(score("nt", "Next Tab").unwrap() > score("nt", "Open Terminal").unwrap());
    }

    #[test]
    fn camel_case_and_separators_count_as_word_starts() {
        assert!(score("rs", "RepoSession").unwrap() > score("rs", "rose").unwrap());
        assert!(score("fb", "feature/branch").unwrap() > score("fb", "fabric").unwrap());
    }
}
