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
