//! A shortest edit script between two sequences (Myers' O(ND) algorithm),
//! used for the blocks, words, code lines and table rows of a Markdown diff.

/// One step of an edit script, by index into the old (`a`) and new (`b`)
/// sequences.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Edit {
    Equal(usize, usize),
    Delete(usize),
    Insert(usize),
}

/// Edits past this many differences give up on the middle: everything in it
/// reads as deleted, then inserted (memory grows with its square).
pub const MAX_EDITS: usize = 1000;

/// The edits turning `a` into `b`: equal runs and, between them, deletions
/// before insertions.
pub fn diff<T: PartialEq>(a: &[T], b: &[T]) -> Vec<Edit> {
    let prefix = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    let suffix = a[prefix..]
        .iter()
        .rev()
        .zip(b[prefix..].iter().rev())
        .take_while(|(x, y)| x == y)
        .count();
    let mut out: Vec<Edit> = (0..prefix).map(|i| Edit::Equal(i, i)).collect();
    let (a_mid, b_mid) = (&a[prefix..a.len() - suffix], &b[prefix..b.len() - suffix]);
    match myers(a_mid, b_mid) {
        Some(middle) => out.extend(middle.into_iter().map(|edit| match edit {
            Edit::Equal(i, j) => Edit::Equal(i + prefix, j + prefix),
            Edit::Delete(i) => Edit::Delete(i + prefix),
            Edit::Insert(j) => Edit::Insert(j + prefix),
        })),
        None => {
            out.extend((0..a_mid.len()).map(|i| Edit::Delete(i + prefix)));
            out.extend((0..b_mid.len()).map(|j| Edit::Insert(j + prefix)));
        }
    }
    let (a_end, b_end) = (a.len() - suffix, b.len() - suffix);
    out.extend((0..suffix).map(|k| Edit::Equal(a_end + k, b_end + k)));
    reorder(out)
}

/// Within each run of changes, deletions come before insertions.
fn reorder(edits: Vec<Edit>) -> Vec<Edit> {
    let mut out = Vec::with_capacity(edits.len());
    let mut inserts = Vec::new();
    for edit in edits {
        match edit {
            Edit::Equal(..) => {
                out.append(&mut inserts);
                out.push(edit);
            }
            Edit::Delete(_) => out.push(edit),
            Edit::Insert(_) => inserts.push(edit),
        }
    }
    out.append(&mut inserts);
    out
}

/// The edit script, or `None` past [`MAX_EDITS`] differences.
fn myers<T: PartialEq>(a: &[T], b: &[T]) -> Option<Vec<Edit>> {
    let (n, m) = (a.len() as isize, b.len() as isize);
    if n == 0 || m == 0 {
        let mut out: Vec<Edit> = (0..a.len()).map(Edit::Delete).collect();
        out.extend((0..b.len()).map(Edit::Insert));
        return Some(out);
    }
    let max = usize::try_from(n + m).unwrap_or(usize::MAX).min(MAX_EDITS) as isize;
    // `v[k + offset]` is the furthest x on diagonal k; `trace[d]` keeps
    // diagonals -d..=d of the round before d.
    let offset = max + 1;
    let mut v = vec![0isize; (2 * offset + 1) as usize];
    let mut trace: Vec<Vec<isize>> = Vec::new();
    for d in 0..=max {
        trace.push(v[(offset - d) as usize..=(offset + d) as usize].to_vec());
        let mut k = -d;
        while k <= d {
            let at = (k + offset) as usize;
            let mut x = if k == -d || (k != d && v[at - 1] < v[at + 1]) {
                v[at + 1]
            } else {
                v[at - 1] + 1
            };
            let mut y = x - k;
            while x < n && y < m && a[x as usize] == b[y as usize] {
                x += 1;
                y += 1;
            }
            v[at] = x;
            if x >= n && y >= m {
                return Some(backtrack(&trace, n, m));
            }
            k += 2;
        }
    }
    None
}

fn backtrack(trace: &[Vec<isize>], n: isize, m: isize) -> Vec<Edit> {
    let mut out = Vec::new();
    let (mut x, mut y) = (n, m);
    for d in (0..trace.len() as isize).rev() {
        let v = &trace[d as usize];
        // `v` holds diagonals -d..=d of the furthest points before round d.
        let get = |k: isize| v[(k + d) as usize];
        let k = x - y;
        let prev_k = if d == 0 {
            0
        } else if k == -d || (k != d && get(k - 1) < get(k + 1)) {
            k + 1
        } else {
            k - 1
        };
        let prev_x = if d == 0 { 0 } else { get(prev_k) };
        let prev_y = prev_x - prev_k;
        while x > prev_x && y > prev_y {
            x -= 1;
            y -= 1;
            out.push(Edit::Equal(x as usize, y as usize));
        }
        if d > 0 {
            if x == prev_x {
                out.push(Edit::Insert(prev_y as usize));
            } else {
                out.push(Edit::Delete(prev_x as usize));
            }
        }
        x = prev_x;
        y = prev_y;
    }
    out.reverse();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Applies `edits` to `a`, checking every step against `a` and `b`.
    fn check(a: &str, b: &str) -> usize {
        let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
        let edits = diff(&a, &b);
        let (mut i, mut j, mut changes) = (0, 0, 0);
        for edit in edits {
            match edit {
                Edit::Equal(x, y) => {
                    assert_eq!((x, y), (i, j));
                    assert_eq!(a[x], b[y]);
                    i += 1;
                    j += 1;
                }
                Edit::Delete(x) => {
                    assert_eq!(x, i);
                    i += 1;
                    changes += 1;
                }
                Edit::Insert(y) => {
                    assert_eq!(y, j);
                    j += 1;
                    changes += 1;
                }
            }
        }
        assert_eq!((i, j), (a.len(), b.len()));
        changes
    }

    #[test]
    fn finds_the_shortest_script() {
        assert_eq!(check("", ""), 0);
        assert_eq!(check("abc", "abc"), 0);
        assert_eq!(check("", "abc"), 3);
        assert_eq!(check("abc", ""), 3);
        assert_eq!(check("abcabba", "cbabac"), 5);
        assert_eq!(check("kitten", "sitting"), 5);
        assert_eq!(check("the quick fox", "the slow fox"), 9);
    }

    #[test]
    fn deletions_come_before_insertions() {
        let edits = diff(&['a', 'x', 'b'], &['a', 'y', 'b']);
        assert_eq!(
            edits,
            vec![
                Edit::Equal(0, 0),
                Edit::Delete(1),
                Edit::Insert(1),
                Edit::Equal(2, 2)
            ]
        );
    }

    #[test]
    fn gives_up_on_huge_differences() {
        let a: Vec<u32> = (0..3000).collect();
        let b: Vec<u32> = (5000..8000).collect();
        let edits = diff(&a, &b);
        assert_eq!(edits.len(), 6000);
        assert!(matches!(edits[0], Edit::Delete(0)));
        assert!(matches!(edits[3000], Edit::Insert(0)));
    }
}
