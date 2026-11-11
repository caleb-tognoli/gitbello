#!/usr/bin/env bash
# Builds the repository `blame_screenshots.tscn` captures: one file written
# by four people over two years (added, grown, renamed, a line here and
# there, a commit that only re-indents, a co-authored one), with two lines
# not committed yet.
#
#   tests/visual/blame_prep.sh <new directory>
#
# The directory must not exist: the script only ever writes inside it.
set -euo pipefail

repo="${1:?usage: blame_prep.sh <new directory>}"
if [ -e "$repo" ]; then
	echo "blame_prep: $repo exists; pass a new directory" >&2
	exit 2
fi
mkdir -p "$repo/src"
cd "$repo"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q -b main .
git config commit.gpgsign false

# commit <author> <email> <date> <subject> [body]
commit() {
	git add -A
	GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" GIT_AUTHOR_DATE="$3" \
	GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$2" GIT_COMMITTER_DATE="$3" \
		git commit -q -m "$4" ${5:+-m "$5"}
}

cat > src/session.rs <<'EOF'
use std::collections::HashMap;
use std::time::{Duration, Instant};

const IDLE_LIMIT: Duration = Duration::from_secs(900);

pub struct Session {
    pub user: String,
    pub token: String,
    pub seen: Instant,
}

pub struct Store {
    sessions: HashMap<String, Session>,
}

impl Store {
    pub fn new() -> Self {
        Store { sessions: HashMap::new() }
    }

    pub fn open(&mut self, user: &str, token: &str) {
        let session = Session {
            user: user.to_string(),
            token: token.to_string(),
            seen: Instant::now(),
        };
        self.sessions.insert(user.to_string(), session);
    }

    pub fn check(&self, user: &str, token: &str) -> bool {
        match self.sessions.get(user) {
            Some(session) => session.token == token,
            None => false,
        }
    }

    pub fn close(&mut self, user: &str) {
        self.sessions.remove(user);
    }
}
EOF
printf '# Sessions\n\nA small session store.\n' > README.md
commit "Ada Rossi" ada@example.com "2024-11-02T10:12:00+01:00" "Add the session store"

cat >> src/session.rs <<'EOF'

/// Drops the sessions nobody used for a while; returns how many.
pub fn expire(store: &mut Store, now: Instant) -> usize {
    let before = store.sessions.len();
    store
        .sessions
        .retain(|_, session| now.duration_since(session.seen) < IDLE_LIMIT);
    before - store.sessions.len()
}
EOF
commit "Marco Bianchi" marco@example.com "2025-01-15T16:40:00+01:00" "Expire idle sessions"

mkdir -p src/server
git mv src/session.rs src/server/session.rs
sed -i 's|^use std::collections::HashMap;|use std::collections::HashMap; // keyed by user|' src/server/session.rs
commit "Ada Rossi" ada@example.com "2025-03-08T09:05:00+01:00" "Move the session store into server"

sed -i '/^    pub fn close(&mut self, user: &str) {/i\
    /// Sessions open right now.\
    pub fn active(&self) -> usize {\
        self.sessions.len()\
    }\
' src/server/session.rs
commit "Priya Nair" priya@example.com "2025-06-21T11:30:00+02:00" "Count the active sessions"

sed -i 's|            Some(session) => session.token == token,|            Some(session) => constant_time_eq(\&session.token, token),|' src/server/session.rs
cat >> src/server/session.rs <<'EOF'

fn constant_time_eq(a: &str, b: &str) -> bool {
    a.len() == b.len()
        && a.bytes().zip(b.bytes()).fold(0, |diff, (x, y)| diff | (x ^ y)) == 0
}
EOF
commit "Marco Bianchi" marco@example.com "2025-09-30T14:22:00+02:00" "Compare tokens in constant time"

sed -i '/^    pub fn check(&self, user: &str, token: &str) -> bool {/i\
    pub fn refresh(\&mut self, user: \&str) {\
        if let Some(session) = self.sessions.get_mut(user) {\
            session.seen = Instant::now();\
            log::debug!("session of {user} refreshed");\
        }\
    }\
' src/server/session.rs
commit "Tom Becker" tom@example.com "2026-02-11T18:03:00+01:00" "Refresh a session when it is used"

# Only whitespace: the struct literal on fewer, re-indented lines.
sed -i 's|^            user: user.to_string(),|          user:  user.to_string(),|; s|^            token: token.to_string(),|          token: token.to_string(),|; s|^            seen: Instant::now(),|          seen:  Instant::now(),|' src/server/session.rs
commit "Priya Nair" priya@example.com "2026-08-19T10:10:00+02:00" "Align the session fields"

sed -i 's|^    pub fn open(&mut self, user: &str, token: &str) {|    pub fn open(\&mut self, user: \&str, token: \&str) -> \&Session {|; s|^        self.sessions.insert(user.to_string(), session);|        self.sessions.insert(user.to_string(), session);\n        \&self.sessions[user]|' src/server/session.rs
commit "Ada Rossi" ada@example.com "2026-10-28T15:45:00+01:00" "Return the session that login opens" \
	"Callers had to look the session up again right after opening it.

Co-authored-by: Tom Becker <tom@example.com>"

sed -i 's|^const IDLE_LIMIT: Duration = Duration::from_secs(900);|const IDLE_LIMIT: Duration = Duration::from_secs(20 * 60);|' src/server/session.rs
commit "Tom Becker" tom@example.com "2026-11-09T09:20:00+01:00" "Give idle sessions twenty minutes"

# Not committed yet.
sed -i 's|^    pub fn close(&mut self, user: &str) {|    pub fn close(\&mut self, user: \&str) {\n        log::debug!("session of {user} closed");|' src/server/session.rs
echo "blame_prep: built $repo"
