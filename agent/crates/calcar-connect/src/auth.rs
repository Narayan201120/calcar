//! Bearer token check against the provisioned token.
//!
//! Failure modes first: a missing header, a non-`Bearer` scheme, and a
//! wrong token all produce the same `false` with no reason attached. The
//! caller turns every `false` into an empty 401, socallers cannot tell
//! "no header" from "wrong token" by status or body.

use tiny_http::Request;

/// True when `Authorization: Bearer <token>` matches byte for byte.
/// Comparison walks the full token so length alone does not shortcut it.
pub fn bearer_ok(request: &Request, token: &str) -> bool {
    for header in request.headers() {
        if !header.field.equiv("Authorization") {
            continue;
        }
        let value = header.value.as_str();
        let presented = match value.strip_prefix("Bearer ") {
            Some(rest) => rest.trim(),
            None => continue,
        };
        return constant_eq(presented.as_bytes(), token.as_bytes());
    }
    false
}

fn constant_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut diff = 0u8;
    for (a, b) in left.iter().zip(right.iter()) {
        diff |= a ^ b;
    }
    diff == 0
}
