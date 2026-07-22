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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_starts_marks_each_line_beginning() {
        assert_eq!(line_starts("a\nb\nc"), vec![0, 2, 4]);
        // A trailing newline opens a final (empty) line.
        assert_eq!(line_starts("a\nb\n"), vec![0, 2, 4]);
        assert_eq!(line_starts(""), vec![0]);
    }

    #[test]
    fn line_count_includes_unterminated_final_line() {
        assert_eq!(line_count("a\nb\nc"), 3);
        assert_eq!(line_count("a\nb\n"), 3);
        assert_eq!(line_count(""), 1);
    }

    #[test]
    fn first_on_line_accepts_only_leading_whitespace() {
        let src = "local a = 1\n\tlocal b = 2\nlocal c = 3 local d = 4\n";
        let ls = line_starts(src);
        assert!(first_on_line(src, 0, 1, &ls));
        let b = src.find("local b").unwrap();
        assert!(first_on_line(src, b, 2, &ls));
        let d = src.find("local d").unwrap();
        assert!(!first_on_line(src, d, 3, &ls));
    }

    #[test]
    fn first_on_line_rejects_out_of_range_inputs() {
        let src = "local a = 1\n";
        let ls = line_starts(src);
        assert!(!first_on_line(src, 0, 0, &ls));
        assert!(!first_on_line(src, 0, 99, &ls));
        assert!(!first_on_line(src, 999, 1, &ls));
    }

    #[test]
    fn sha256_hex_matches_known_digest() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }
}
