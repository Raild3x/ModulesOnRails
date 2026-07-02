//! Parsing + source-position helpers shared by the collectors.

use full_moon::ast::Ast;

pub fn parse(src: &str) -> Result<Ast, Vec<full_moon::Error>> {
    full_moon::parse(src)
}

/// Byte offsets (0-based) where each 1-based line begins.
pub fn line_starts(src: &str) -> Vec<usize> {
    let mut v = vec![0usize];
    for (i, b) in src.bytes().enumerate() {
        if b == b'\n' {
            v.push(i + 1);
        }
    }
    v
}

pub fn line_count(src: &str) -> usize {
    src.bytes().filter(|&b| b == b'\n').count() + 1
}

/// True if everything between the start of `line` (1-based) and `byte` is
/// whitespace — i.e. the anchor is the first token on its line.
pub fn first_on_line(src: &str, byte: usize, line: usize, line_starts: &[usize]) -> bool {
    if line == 0 || line > line_starts.len() {
        return false;
    }
    let start = line_starts[line - 1];
    if byte < start || byte > src.len() {
        return false;
    }
    src[start..byte].bytes().all(|b| b == b' ' || b == b'\t')
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(bytes);
    let out = h.finalize();
    let mut s = String::with_capacity(out.len() * 2);
    for b in out {
        s.push_str(&format!("{:02x}", b));
    }
    s
}
