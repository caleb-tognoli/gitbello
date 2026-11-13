//! Module docs.
use std::collections::HashMap;

/// A point in 2D.
#[derive(Debug, Clone, Copy)]
pub struct Point<'a> {
    pub x: f64,
    name: &'a str,
}

impl<'a> Point<'a> {
    pub const ORIGIN_NAME: &'static str = "origin";

    pub fn new(x: f64, name: &'a str) -> Self {
        Self { x, name }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut map: HashMap<u32, String> = HashMap::new();
    let c = 'c'; let nl = '\n'; let q = '\'';
    let raw = r"C:\path"; let bytes = b"abc";
    let hashed = r#"a "raw" one"#; const LIMIT: usize = 3;
    let s = "a \"quoted\" word"; /* inline block */ let n = 0x1F_u8;
    for i in 0..10 {
        map.insert(i, format!("{i}: {:?}", 1.5e3));
    }
    println!("{}", map.len()); // trailing comment
    if let Some(v) = map.get(&3) { return Ok(()); }
    let multi = "a string that
        goes on"; let after = 1;
    /* a block comment
       over two lines */
    let raw = r#"raw "text"
        on two lines"#;
    Ok(())
}
