//! Reads the ref-update commands at the start of a smart-HTTP
//! `git-receive-pack` request body, before the pack data.

/// Commands larger than this are not a push any client sends; refusing them
/// bounds how much of a request the proxy holds before deciding.
pub const MAX_COMMANDS_LEN: usize = 1 << 20;

#[derive(Debug, PartialEq, Eq)]
pub struct RefUpdate {
    pub old: String,
    pub new: String,
    pub name: String,
}

impl RefUpdate {
    pub fn is_delete(&self) -> bool {
        self.new.bytes().all(|byte| byte == b'0')
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Parse {
    /// More bytes are needed.
    Incomplete,
    Commands(Vec<RefUpdate>),
    Invalid(String),
}

pub fn parse_commands(buf: &[u8]) -> Parse {
    let mut updates = Vec::new();
    let mut at = 0;
    loop {
        let Some(header) = buf.get(at..at + 4) else {
            return incomplete(buf);
        };
        let Some(len) = std::str::from_utf8(header)
            .ok()
            .and_then(|hex| usize::from_str_radix(hex, 16).ok())
        else {
            return Parse::Invalid("malformed pkt-line length".into());
        };
        if len == 0 {
            // A lone flush is git's auth probe before a large chunked push;
            // it updates nothing.
            return Parse::Commands(updates);
        }
        if len < 4 {
            return Parse::Invalid(format!("unexpected special pkt-line {len:04x}"));
        }
        let Some(payload) = buf.get(at + 4..at + len) else {
            return incomplete(buf);
        };
        at += len;

        let payload = payload.strip_suffix(b"\n").unwrap_or(payload);
        // The first command carries capabilities after a NUL.
        let line = payload.split(|&byte| byte == 0).next().unwrap_or_default();
        let Ok(line) = std::str::from_utf8(line) else {
            return Parse::Invalid("ref update is not UTF-8".into());
        };
        if line.starts_with("shallow ") {
            continue;
        }
        if line.starts_with("push-cert") {
            return Parse::Invalid("signed pushes are not supported".into());
        }
        match parse_update(line) {
            Some(update) => updates.push(update),
            None => return Parse::Invalid(format!("malformed ref update {line:?}")),
        }
    }
}

fn incomplete(buf: &[u8]) -> Parse {
    if buf.len() > MAX_COMMANDS_LEN {
        Parse::Invalid("ref update section is too large".into())
    } else {
        Parse::Incomplete
    }
}

fn parse_update(line: &str) -> Option<RefUpdate> {
    let mut fields = line.split(' ');
    let (old, new, name) = (fields.next()?, fields.next()?, fields.next()?);
    let is_oid = |oid: &str| {
        (oid.len() == 40 || oid.len() == 64) && oid.bytes().all(|b| b.is_ascii_hexdigit())
    };
    if fields.next().is_some() || !is_oid(old) || !is_oid(new) || !name.starts_with("refs/") {
        return None;
    }
    Some(RefUpdate {
        old: old.to_owned(),
        new: new.to_owned(),
        name: name.to_owned(),
    })
}

#[cfg(test)]
pub(crate) fn pkt(line: &str) -> Vec<u8> {
    let mut out = format!("{:04x}", line.len() + 4).into_bytes();
    out.extend_from_slice(line.as_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "1111111111111111111111111111111111111111";
    const B: &str = "2222222222222222222222222222222222222222";
    const ZERO: &str = "0000000000000000000000000000000000000000";

    fn body(lines: &[String]) -> Vec<u8> {
        let mut out: Vec<u8> = lines.iter().flat_map(|line| pkt(line)).collect();
        out.extend_from_slice(b"0000PACK....");
        out
    }

    #[test]
    fn reads_every_ref_update_and_ignores_capabilities_and_shallow_lines() {
        let buf = body(&[
            format!("shallow {A}"),
            format!("{A} {B} refs/heads/main\0report-status side-band-64k\n"),
            format!("{B} {ZERO} refs/heads/old\n"),
        ]);
        let Parse::Commands(updates) = parse_commands(&buf) else {
            panic!("expected commands");
        };
        assert_eq!(updates.len(), 2);
        assert_eq!(updates[0].name, "refs/heads/main");
        assert!(!updates[0].is_delete());
        assert!(updates[1].is_delete());
    }

    #[test]
    fn every_truncation_of_a_valid_body_asks_for_more_bytes() {
        let buf = body(&[format!("{A} {B} refs/heads/main\0caps\n")]);
        let flush = buf.windows(4).position(|w| w == b"0000").expect("flush");
        for end in 0..flush + 4 {
            assert_eq!(parse_commands(&buf[..end]), Parse::Incomplete, "at {end}");
        }
    }

    #[test]
    fn signed_pushes_and_garbage_are_refused() {
        for buf in [
            body(&["push-cert\0caps\n".into()]),
            b"zzzz".to_vec(),
            body(&[format!("{A} {B} HEAD\n")]),
            body(&[format!("{A} {B} refs/heads/a extra\n")]),
        ] {
            assert!(matches!(parse_commands(&buf), Parse::Invalid(_)));
        }
    }

    #[test]
    fn a_lone_flush_is_an_empty_push() {
        assert_eq!(parse_commands(b"0000"), Parse::Commands(Vec::new()));
    }
}
