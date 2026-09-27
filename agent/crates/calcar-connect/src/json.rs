//! Minimal JSON value model, renderer, and parser.
//!
//! Failure modes first: parse errors are one opaque `Malformed` with no
//! offset or excerpt (error strings must never carry request data, P7
//! privacy). Numbers that do not fit `i64` become `f64`; the server only
//! needs string, bool, and small-int fields, and anything else surfaces as
//! 400 through the typed getters. Depth is capped so a nested `[[[[`
//! payload cannot stack-overflow the parser.

use std::collections::BTreeMap;

/// One JSON value. Objects keep key order sorted; the phone parses maps,
// which never observe order.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Arr(Vec<Value>),
    Obj(BTreeMap<String, Value>),
}

impl Value {
    pub fn str_field(&self, key: &str) -> Option<&str> {
        match self {
            Value::Obj(map) => match map.get(key) {
                Some(Value::Str(value)) => Some(value),
                _ => None,
            },
            _ => None,
        }
    }

    pub fn bool_field(&self, key: &str) -> Option<bool> {
        match self {
            Value::Obj(map) => match map.get(key) {
                Some(Value::Bool(value)) => Some(*value),
                _ => None,
            },
            _ => None,
        }
    }

    pub fn int_field(&self, key: &str) -> Option<i64> {
        match self {
            Value::Obj(map) => match map.get(key) {
                Some(Value::Int(value)) => Some(*value),
                _ => None,
            },
            _ => None,
        }
    }
}

/// Render a value to its JSON text. Strings are escaped per RFC 8259,
/// including control characters as `\u00XX`; nothing else needs escaping.
pub fn render(value: &Value) -> String {
    let mut out = String::new();
    write_value(&mut out, value);
    out
}

fn write_value(out: &mut String, value: &Value) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Int(n) => out.push_str(&n.to_string()),
        Value::Float(f) => {
            if f.is_finite() {
                out.push_str(&format!("{f:?}"));
            } else {
                out.push_str("null");
            }
        }
        Value::Str(text) => write_string(out, text),
        Value::Arr(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_value(out, item);
            }
            out.push(']');
        }
        Value::Obj(map) => {
            out.push('{');
            for (index, (key, item)) in map.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(out, key);
                out.push(':');
                write_value(out, item);
            }
            out.push('}');
        }
    }
}

fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if (ch as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", ch as u32));
            }
            ch => out.push(ch),
        }
    }
    out.push('"');
}

/// Build an object from ordered key/value pairs.
pub fn obj(pairs: Vec<(&str, Value)>) -> Value {
    Value::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

/// Opaque parse failure. No offset, no excerpt: request bytes stay out of
/// error strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Malformed;

const MAX_DEPTH: usize = 64;

/// Parse one JSON document. Trailing bytes after the value are refused.
pub fn parse(text: &str) -> Result<Value, Malformed> {
    let bytes = text.as_bytes();
    let mut parser = Parser { bytes, pos: 0 };
    parser.skip_ws();
    let value = parser.value(0)?;
    parser.skip_ws();
    if parser.pos != bytes.len() {
        return Err(Malformed);
    }
    Ok(value)
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl Parser<'_> {
    fn skip_ws(&mut self) {
        while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_whitespace() {
            self.pos += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn lit(&mut self, word: &[u8]) -> Result<(), Malformed> {
        if self.bytes[self.pos..].starts_with(word) {
            self.pos += word.len();
            Ok(())
        } else {
            Err(Malformed)
        }
    }

    fn value(&mut self, depth: usize) -> Result<Value, Malformed> {
        if depth > MAX_DEPTH {
            return Err(Malformed);
        }
        match self.peek().ok_or(Malformed)? {
            b'{' => self.object(depth),
            b'[' => self.array(depth),
            b'"' => Ok(Value::Str(self.string()?)),
            b't' => {
                self.lit(b"true")?;
                Ok(Value::Bool(true))
            }
            b'f' => {
                self.lit(b"false")?;
                Ok(Value::Bool(false))
            }
            b'n' => {
                self.lit(b"null")?;
                Ok(Value::Null)
            }
            b'-' | b'0'..=b'9' => self.number(),
            _ => Err(Malformed),
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value, Malformed> {
        self.pos += 1; // {
        let mut map = BTreeMap::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Value::Obj(map));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(Malformed);
            }
            let key = self.string()?;
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Err(Malformed);
            }
            self.pos += 1;
            self.skip_ws();
            map.insert(key, self.value(depth + 1)?);
            self.skip_ws();
            match self.peek().ok_or(Malformed)? {
                b',' => {
                    self.pos += 1;
                }
                b'}' => {
                    self.pos += 1;
                    return Ok(Value::Obj(map));
                }
                _ => return Err(Malformed),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Value, Malformed> {
        self.pos += 1; // [
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Value::Arr(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value(depth + 1)?);
            self.skip_ws();
            match self.peek().ok_or(Malformed)? {
                b',' => {
                    self.pos += 1;
                }
                b']' => {
                    self.pos += 1;
                    return Ok(Value::Arr(items));
                }
                _ => return Err(Malformed),
            }
        }
    }

    fn string(&mut self) -> Result<String, Malformed> {
        self.pos += 1; // opening quote
        let mut out = String::new();
        loop {
            let byte = *self.bytes.get(self.pos).ok_or(Malformed)?;
            match byte {
                b'"' => {
                    self.pos += 1;
                    return Ok(out);
                }
                b'\\' => {
                    self.pos += 1;
                    let esc = *self.bytes.get(self.pos).ok_or(Malformed)?;
                    self.pos += 1;
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{0008}'),
                        b'f' => out.push('\u{000C}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let code = self.hex4()?;
                            match char::from_u32(code) {
                                Some(ch) => out.push(ch),
                                None => return Err(Malformed),
                            }
                        }
                        _ => return Err(Malformed),
                    }
                }
                0x00..=0x1F => return Err(Malformed),
                _ => {
                    let rest = &self.bytes[self.pos..];
                    let text = std::str::from_utf8(rest).map_err(|_| Malformed)?;
                    let ch = text.chars().next().ok_or(Malformed)?;
                    out.push(ch);
                    self.pos += ch.len_utf8();
                }
            }
        }
    }

    fn hex4(&mut self) -> Result<u32, Malformed> {
        if self.pos + 4 > self.bytes.len() {
            return Err(Malformed);
        }
        let digits =
            std::str::from_utf8(&self.bytes[self.pos..self.pos + 4]).map_err(|_| Malformed)?;
        let code = u32::from_str_radix(digits, 16).map_err(|_| Malformed)?;
        self.pos += 4;
        Ok(code)
    }

    fn number(&mut self) -> Result<Value, Malformed> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        let mut is_float = false;
        while let Some(b'0'..=b'9') = self.peek() {
            self.pos += 1;
        }
        if self.peek() == Some(b'.') {
            is_float = true;
            self.pos += 1;
            while let Some(b'0'..=b'9') = self.peek() {
                self.pos += 1;
            }
        }
        if matches!(self.peek(), Some(b'e') | Some(b'E')) {
            is_float = true;
            self.pos += 1;
            if matches!(self.peek(), Some(b'+') | Some(b'-')) {
                self.pos += 1;
            }
            while let Some(b'0'..=b'9') = self.peek() {
                self.pos += 1;
            }
        }
        let text = std::str::from_utf8(&self.bytes[start..self.pos]).map_err(|_| Malformed)?;
        if text.is_empty() || text == "-" {
            return Err(Malformed);
        }
        if is_float {
            text.parse::<f64>().map(Value::Float).map_err(|_| Malformed)
        } else {
            match text.parse::<i64>() {
                Ok(n) => Ok(Value::Int(n)),
                Err(_) => text.parse::<f64>().map(Value::Float).map_err(|_| Malformed),
            }
        }
    }
}
