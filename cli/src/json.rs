//! Just enough JSON to print what the parser read.
//!
//! `mealplan validate --json` exists so that "how was this line read" can be
//! asked of the parser itself. Adding a JSON serialiser crate for four object
//! shapes would be more code to audit than this.

pub fn string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if (control as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", control as u32));
            }
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

pub fn field(name: &str, value: String) -> String {
    format!("{}:{}", string(name), value)
}

pub fn object(fields: Vec<String>) -> String {
    format!("{{{}}}", fields.join(","))
}

pub fn array(items: Vec<String>) -> String {
    format!("[{}]", items.join(","))
}

pub fn null() -> String {
    "null".to_string()
}

pub fn boolean(value: bool) -> String {
    value.to_string()
}

// --- reading ---------------------------------------------------------------
//
// `mealplan plan candidates --attach` takes its payload on standard input, so
// the CLI needs a reader as well as a writer. Hand-written for the same reason
// the writer is (ADR 0007): the shapes are small, and a crate here would be
// more code to audit than this is to read.
//
// Tolerant where tolerance is free and strict where it is not: any value
// parses, but a trailing comma, an unterminated string or a stray byte is an
// error that names the character offset, because the payload is built by
// another program and a silent misread would attach candidates to the wrong
// line.

use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Value>),
    Object(BTreeMap<String, Value>),
}

impl Value {
    /// The string at `key`, when this is an object holding one.
    pub fn get_str(&self, key: &str) -> Option<&str> {
        match self.get(key) {
            Some(Value::String(text)) => Some(text),
            _ => None,
        }
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(fields) => fields.get(key),
            _ => None,
        }
    }

    pub fn as_array(&self) -> &[Value] {
        match self {
            Value::Array(items) => items,
            _ => &[],
        }
    }

    pub fn as_object(&self) -> Option<&BTreeMap<String, Value>> {
        match self {
            Value::Object(fields) => Some(fields),
            _ => None,
        }
    }

    /// The text of a string, or of a number written as one. The retailer
    /// tools send `count` both ways depending on the caller, and a count is
    /// text in the document either way.
    pub fn as_text(&self) -> Option<String> {
        match self {
            Value::String(text) => Some(text.clone()),
            Value::Number(value) => Some(format_number(*value)),
            _ => None,
        }
    }
}

fn format_number(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        format!("{value}")
    }
}

/// Parse one JSON document. `Err` names the offset, in characters.
pub fn parse(source: &str) -> Result<Value, String> {
    let characters: Vec<char> = source.chars().collect();
    let mut at = 0usize;
    skip_space(&characters, &mut at);
    let value = parse_value(&characters, &mut at)?;
    skip_space(&characters, &mut at);
    if at < characters.len() {
        return Err(format!(
            "unexpected `{}` at character {at}, after the value ended",
            characters[at]
        ));
    }
    Ok(value)
}

fn skip_space(characters: &[char], at: &mut usize) {
    while *at < characters.len() && characters[*at].is_whitespace() {
        *at += 1;
    }
}

fn parse_value(characters: &[char], at: &mut usize) -> Result<Value, String> {
    match characters.get(*at) {
        None => Err("the payload ended before a value started".to_string()),
        Some('{') => parse_object(characters, at),
        Some('[') => parse_array(characters, at),
        Some('"') => Ok(Value::String(parse_string(characters, at)?)),
        Some('t') => literal(characters, at, "true", Value::Bool(true)),
        Some('f') => literal(characters, at, "false", Value::Bool(false)),
        Some('n') => literal(characters, at, "null", Value::Null),
        Some(_) => parse_number(characters, at),
    }
}

fn literal(characters: &[char], at: &mut usize, word: &str, value: Value) -> Result<Value, String> {
    for expected in word.chars() {
        if characters.get(*at) != Some(&expected) {
            return Err(format!("expected `{word}` at character {at}"));
        }
        *at += 1;
    }
    Ok(value)
}

fn parse_object(characters: &[char], at: &mut usize) -> Result<Value, String> {
    *at += 1; // the '{'
    let mut fields = BTreeMap::new();
    skip_space(characters, at);
    if characters.get(*at) == Some(&'}') {
        *at += 1;
        return Ok(Value::Object(fields));
    }
    loop {
        skip_space(characters, at);
        if characters.get(*at) != Some(&'"') {
            return Err(format!("expected a key in quotes at character {at}"));
        }
        let key = parse_string(characters, at)?;
        skip_space(characters, at);
        if characters.get(*at) != Some(&':') {
            return Err(format!("expected `:` after the key at character {at}"));
        }
        *at += 1;
        skip_space(characters, at);
        fields.insert(key, parse_value(characters, at)?);
        skip_space(characters, at);
        match characters.get(*at) {
            Some(',') => *at += 1,
            Some('}') => {
                *at += 1;
                return Ok(Value::Object(fields));
            }
            _ => return Err(format!("expected `,` or `}}` at character {at}")),
        }
    }
}

fn parse_array(characters: &[char], at: &mut usize) -> Result<Value, String> {
    *at += 1; // the '['
    let mut items = Vec::new();
    skip_space(characters, at);
    if characters.get(*at) == Some(&']') {
        *at += 1;
        return Ok(Value::Array(items));
    }
    loop {
        skip_space(characters, at);
        items.push(parse_value(characters, at)?);
        skip_space(characters, at);
        match characters.get(*at) {
            Some(',') => *at += 1,
            Some(']') => {
                *at += 1;
                return Ok(Value::Array(items));
            }
            _ => return Err(format!("expected `,` or `]` at character {at}")),
        }
    }
}

fn parse_string(characters: &[char], at: &mut usize) -> Result<String, String> {
    *at += 1; // the opening quote
    let mut out = String::new();
    loop {
        match characters.get(*at) {
            None => return Err("a string was never closed".to_string()),
            Some('"') => {
                *at += 1;
                return Ok(out);
            }
            Some('\\') => {
                *at += 1;
                let escape = characters
                    .get(*at)
                    .ok_or_else(|| "a string ended inside an escape".to_string())?;
                match escape {
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    'b' => out.push('\u{08}'),
                    'f' => out.push('\u{0c}'),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'u' => {
                        *at += 1;
                        out.push(parse_escape_u(characters, at)?);
                        continue;
                    }
                    other => return Err(format!("`\\{other}` is not an escape, at character {at}")),
                }
                *at += 1;
            }
            Some(other) => {
                out.push(*other);
                *at += 1;
            }
        }
    }
}

// A surrogate pair is two \u escapes and has to be rejoined, or every product
// description with an emoji or a rare character comes back as two replacement
// characters. Counted in chars, not bytes — see the em-dash trap in
// docs/plans/0007-progress.md.
fn parse_escape_u(characters: &[char], at: &mut usize) -> Result<char, String> {
    let first = hex4(characters, at)?;
    if (0xD800..0xDC00).contains(&first) {
        if characters.get(*at) == Some(&'\\') && characters.get(*at + 1) == Some(&'u') {
            *at += 2;
            let second = hex4(characters, at)?;
            if (0xDC00..0xE000).contains(&second) {
                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
                return char::from_u32(combined)
                    .ok_or_else(|| format!("\\u{first:04x} is not a character"));
            }
        }
        return Ok('\u{fffd}');
    }
    char::from_u32(first).ok_or_else(|| format!("\\u{first:04x} is not a character"))
}

fn hex4(characters: &[char], at: &mut usize) -> Result<u32, String> {
    let mut value = 0u32;
    for _ in 0..4 {
        let digit = characters
            .get(*at)
            .and_then(|character| character.to_digit(16))
            .ok_or_else(|| format!("expected four hex digits at character {at}"))?;
        value = value * 16 + digit;
        *at += 1;
    }
    Ok(value)
}

fn parse_number(characters: &[char], at: &mut usize) -> Result<Value, String> {
    let start = *at;
    // Say what was actually there. Falling through to "`` is not a number"
    // told the reader nothing, and this message is the documentation for a
    // payload another program built.
    match characters.get(*at) {
        Some(character) if character.is_ascii_digit() || *character == '-' => {}
        Some(character) => {
            return Err(format!(
                "`{character}` at character {start} starts no value — a value is an object, an \
                 array, a string in quotes, a number, true, false or null"
            ));
        }
        None => return Err("the payload ended before a value started".to_string()),
    }
    if characters.get(*at) == Some(&'-') {
        *at += 1;
    }
    while matches!(characters.get(*at), Some(character) if character.is_ascii_digit()
        || *character == '.' || *character == 'e' || *character == 'E'
        || *character == '+' || *character == '-')
    {
        *at += 1;
    }
    let text: String = characters[start..*at].iter().collect();
    text.parse::<f64>()
        .map(Value::Number)
        .map_err(|_| format!("`{text}` is not a number, at character {start}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn object(source: &str) -> Value {
        parse(source).expect("parses")
    }

    #[test]
    fn reads_the_attach_payload_shape() {
        let value = object(
            r#"{"found":{"1 lb beef — Tue":[{"id":"0001","count":"2","description":"Beef"}]},
                "searches":{"1 lb beef — Tue":"ground beef"},
                "notFound":["8 oz olives — Wed"]}"#,
        );
        let found = value.get("found").expect("found").as_object().expect("object");
        let candidates = found["1 lb beef — Tue"].as_array();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].get_str("id"), Some("0001"));
        assert_eq!(
            value.get("searches").unwrap().get_str("1 lb beef — Tue"),
            Some("ground beef")
        );
        assert_eq!(value.get("notFound").unwrap().as_array().len(), 1);
    }

    #[test]
    fn an_em_dash_in_a_key_survives() {
        // The anchor holds an em dash on every line that names its nights. A
        // reader that counted bytes would split it.
        let value = object(r#"{"2 lb rice — Mon, Tue":1}"#);
        assert!(value.get("2 lb rice — Mon, Tue").is_some());
    }

    #[test]
    fn escapes_come_back_as_characters() {
        let value = object(r#"{"a":"quote \" slash \\ newline \n tab \t unicode é"}"#);
        assert_eq!(value.get_str("a"), Some("quote \" slash \\ newline \n tab \t unicode é"));
    }

    #[test]
    fn a_surrogate_pair_rejoins() {
        let value = object(r#"{"a":"🥚 egg"}"#);
        assert_eq!(value.get_str("a"), Some("🥚 egg"));
    }

    #[test]
    fn a_lone_surrogate_does_not_panic() {
        let value = object(r#"{"a":"\ud83e"}"#);
        assert_eq!(value.get_str("a"), Some("\u{fffd}"));
    }

    #[test]
    fn a_count_reads_as_text_whether_it_is_a_number_or_a_string() {
        let value = object(r#"{"a":2,"b":"2"}"#);
        assert_eq!(value.get("a").unwrap().as_text(), Some("2".to_string()));
        assert_eq!(value.get("b").unwrap().as_text(), Some("2".to_string()));
    }

    #[test]
    fn empty_containers_parse() {
        assert_eq!(parse("{}"), Ok(Value::Object(BTreeMap::new())));
        assert_eq!(parse("[]"), Ok(Value::Array(vec![])));
    }

    #[test]
    fn nulls_and_booleans_parse() {
        let value = object(r#"{"a":null,"b":true,"c":false}"#);
        assert_eq!(value.get("a"), Some(&Value::Null));
        assert_eq!(value.get("b"), Some(&Value::Bool(true)));
        assert_eq!(value.get("c"), Some(&Value::Bool(false)));
    }

    #[test]
    fn a_payload_that_is_not_json_at_all_says_so() {
        // `oops` used to give "`` is not a number", which told the reader
        // nothing about a payload another program built.
        let error = parse("oops").expect_err("refused");
        assert!(error.contains("`o` at character 0 starts no value"), "{error}");
        assert!(error.contains("true, false or null"), "{error}");
    }

    #[test]
    fn a_malformed_payload_names_the_offset() {
        // Silence here would attach candidates to the wrong line.
        for bad in [r#"{"a":1,}"#, r#"{"a" 1}"#, r#"{"a":"unterminated"#, r#"{"a":1}x"#] {
            let error = parse(bad).expect_err(bad);
            assert!(
                error.contains("character") || error.contains("never closed"),
                "{bad} gave {error}"
            );
        }
    }

    #[test]
    fn the_writer_and_the_reader_agree() {
        let written = object_written();
        let read = parse(&written).expect("round trips");
        assert_eq!(read.get_str("description"), Some("Beef — 93% lean, \"lean\""));
    }

    fn object_written() -> String {
        super::object(vec![super::field(
            "description",
            super::string("Beef — 93% lean, \"lean\""),
        )])
    }
}
