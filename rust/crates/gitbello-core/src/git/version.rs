use std::fmt;

/// Oldest git that gitbello supports (PLAN D5).
pub const MIN_GIT_VERSION: GitVersion = GitVersion::new(2, 40, 0);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct GitVersion {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl GitVersion {
    pub const fn new(major: u32, minor: u32, patch: u32) -> Self {
        Self {
            major,
            minor,
            patch,
        }
    }

    /// Parses `git --version` output, such as `git version 2.53.0.windows.3`
    /// or `git version 2.39.3 (Apple Git-146)`.
    pub fn parse(output: &str) -> Option<Self> {
        let rest = output.trim().strip_prefix("git version ")?;
        let version = rest.split_whitespace().next()?;
        let mut parts = version.split('.').map(|part| {
            let digits: String = part.chars().take_while(char::is_ascii_digit).collect();
            digits.parse::<u32>().ok()
        });
        let major = parts.next()??;
        let minor = parts.next()??;
        let patch = parts.next().flatten().unwrap_or(0);
        Some(Self::new(major, minor, patch))
    }
}

impl fmt::Display for GitVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_common_formats() {
        let cases = [
            ("git version 2.53.0.windows.3\n", GitVersion::new(2, 53, 0)),
            (
                "git version 2.39.3 (Apple Git-146)",
                GitVersion::new(2, 39, 3),
            ),
            ("git version 2.43.0", GitVersion::new(2, 43, 0)),
            ("git version 2.45", GitVersion::new(2, 45, 0)),
            ("git version 2.47.0.rc1", GitVersion::new(2, 47, 0)),
        ];
        for (input, expected) in cases {
            assert_eq!(GitVersion::parse(input), Some(expected), "{input}");
        }
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(GitVersion::parse(""), None);
        assert_eq!(GitVersion::parse("hg version 6.0"), None);
        assert_eq!(GitVersion::parse("git version x.y"), None);
    }

    #[test]
    fn orders_versions() {
        assert!(GitVersion::new(2, 39, 9) < MIN_GIT_VERSION);
        assert!(GitVersion::new(2, 40, 0) >= MIN_GIT_VERSION);
        assert!(GitVersion::new(3, 0, 0) > MIN_GIT_VERSION);
    }
}
