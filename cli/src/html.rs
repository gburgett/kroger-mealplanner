//! A tolerant HTML scanner, and just enough of one.
//!
//! ADR 0037 makes the meal plan an HTML document that the assistant edits and
//! posts back. Something has to read that document, and it is this, in the CLI,
//! because ADR 0007 says the corpus parser lives in exactly one place.
//!
//! This is NOT a compliant HTML parser and does not try to be. It has one job:
//! find the elements that carry `data-mp-*` attributes, and read their
//! attributes and their text. Everything else about the document — the styles,
//! the headings, the layout — is chrome that `render.rs` wrote and will write
//! again.
//!
//! Tolerant means specific things, and each is here because an assistant
//! editing a document by hand will do it:
//!
//!   * A closing tag with nothing open to close is ignored, not an error.
//!   * A tag left unclosed is closed by its parent's closing tag. A document
//!     that lost a `</div>` still parses, and `plan.rs` still finds every day.
//!   * An attribute with no value is a present attribute with an empty value.
//!   * `<script>` and `<style>` hold text, not markup, so a `<` inside them
//!     does not open anything.
//!
//! Adding a crate for this was the alternative. `json.rs` is a hand-written
//! writer for the same reason: the sandbox image ships this binary, and a
//! dependency here is a dependency inside the boundary.

/// A parsed element: its tag, its attributes in document order, its children.
#[derive(Debug, Clone)]
pub struct Element {
    pub tag: String,
    pub attributes: Vec<(String, String)>,
    pub children: Vec<Node>,
}

#[derive(Debug, Clone)]
pub enum Node {
    Element(Element),
    Text(String),
}

/// Elements that never have a closing tag.
const VOID: &[&str] = &[
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
    "track", "wbr",
];

/// Elements whose content is text, not markup.
const RAW_TEXT: &[&str] = &["script", "style", "textarea", "title"];

impl Element {
    /// An attribute's value, if the element carries it. Names are compared in
    /// lower case, because an assistant may write `DATA-MP-DAY`.
    pub fn attribute(&self, name: &str) -> Option<&str> {
        let wanted = name.to_ascii_lowercase();
        self.attributes
            .iter()
            .find(|(key, _)| *key == wanted)
            .map(|(_, value)| value.as_str())
    }

    pub fn has_attribute(&self, name: &str) -> bool {
        self.attribute(name).is_some()
    }

    /// Every descendant element, depth first, this one included.
    pub fn descendants(&self) -> Vec<&Element> {
        let mut found = Vec::new();
        collect(self, &mut found);
        found
    }

    /// The elements below this one carrying `name`, depth first. Does not
    /// include this element, so a day looking for its meals cannot find itself.
    pub fn find_all(&self, name: &str) -> Vec<&Element> {
        let wanted = name.to_ascii_lowercase();
        self.descendants()
            .into_iter()
            .filter(|element| !std::ptr::eq(*element, self))
            .filter(|element| element.attributes.iter().any(|(key, _)| *key == wanted))
            .collect()
    }

    /// The first element below this one carrying `name`.
    pub fn find(&self, name: &str) -> Option<&Element> {
        self.find_all(name).into_iter().next()
    }

    /// All the text under this element, with runs of whitespace collapsed to
    /// one space and the ends trimmed. That is what a shopping-list line or an
    /// ingredient line reads as, and it is what has to match `render_line`.
    pub fn text(&self) -> String {
        let mut raw = String::new();
        gather_text(self, &mut raw);
        collapse(&raw)
    }
}

fn collect<'a>(element: &'a Element, found: &mut Vec<&'a Element>) {
    found.push(element);
    for child in &element.children {
        if let Node::Element(child) = child {
            collect(child, found);
        }
    }
}

fn gather_text(element: &Element, out: &mut String) {
    // Script and style hold code, never prose. Their text is never part of
    // what the document says.
    if RAW_TEXT.contains(&element.tag.as_str()) {
        return;
    }
    for child in &element.children {
        match child {
            Node::Text(text) => out.push_str(text),
            Node::Element(child) => gather_text(child, out),
        }
    }
}

pub fn collapse(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    for character in text.chars() {
        if character.is_whitespace() {
            space = !out.is_empty();
        } else {
            if space {
                out.push(' ');
            }
            space = false;
            out.push(character);
        }
    }
    out
}

/// Parse a document into one synthetic root element holding everything.
///
/// There is no error return. Any byte sequence is some tree, which is the
/// point: a document that fails to parse would give the assistant nothing to
/// fix, and `plan.rs` reports what it could not FIND in terms of the plan,
/// which is a message somebody can act on.
pub fn parse(source: &str) -> Element {
    let mut parser = Parser { bytes: source.as_bytes(), source, at: 0 };
    let mut root = Element { tag: "#document".to_string(), attributes: Vec::new(), children: Vec::new() };
    let mut stack: Vec<Element> = Vec::new();

    while parser.at < parser.bytes.len() {
        if parser.bytes[parser.at] == b'<' {
            if parser.starts_with("<!--") {
                parser.skip_comment();
                continue;
            }
            if parser.starts_with("<!") || parser.starts_with("<?") {
                parser.skip_to(b'>');
                continue;
            }
            if parser.starts_with("</") {
                let name = parser.read_closing_tag();
                close(&mut stack, &mut root, &name);
                continue;
            }
            if let Some((element, self_closing)) = parser.read_open_tag() {
                let tag = element.tag.clone();
                let raw_text = RAW_TEXT.contains(&tag.as_str());
                let empty = self_closing || VOID.contains(&tag.as_str());

                if empty {
                    push_child(&mut stack, &mut root, Node::Element(element));
                } else {
                    stack.push(element);
                    if raw_text {
                        let text = parser.read_raw_text(&tag);
                        if !text.is_empty() {
                            push_child(&mut stack, &mut root, Node::Text(text));
                        }
                        // read_raw_text stops before the closing tag; consume it.
                        if parser.starts_with("</") {
                            let name = parser.read_closing_tag();
                            close(&mut stack, &mut root, &name);
                        }
                    }
                }
                continue;
            }
            // A bare `<` that opens nothing is text.
            parser.at += 1;
            push_child(&mut stack, &mut root, Node::Text("<".to_string()));
            continue;
        }

        let text = parser.read_text();
        if !text.is_empty() {
            push_child(&mut stack, &mut root, Node::Text(decode(&text)));
        }
    }

    // Whatever is still open was never closed. Close it, innermost first, so a
    // document that lost a closing tag still yields its whole tree.
    while let Some(element) = stack.pop() {
        push_child(&mut stack, &mut root, Node::Element(element));
    }

    root
}

fn push_child(stack: &mut [Element], root: &mut Element, node: Node) {
    match stack.last_mut() {
        Some(parent) => parent.children.push(node),
        None => root.children.push(node),
    }
}

/// Close the innermost matching open element.
///
/// If `name` is open further up, everything inside it is closed too — that is
/// what rescues a dropped `</div>`. If it is not open at all, the closing tag
/// is ignored rather than treated as an error.
fn close(stack: &mut Vec<Element>, root: &mut Element, name: &str) {
    let Some(index) = stack.iter().rposition(|element| element.tag == name) else {
        return;
    };
    while stack.len() > index {
        let element = stack.pop().expect("checked by the position above");
        push_child(stack, root, Node::Element(element));
    }
}

struct Parser<'a> {
    bytes: &'a [u8],
    source: &'a str,
    at: usize,
}

impl<'a> Parser<'a> {
    fn starts_with(&self, prefix: &str) -> bool {
        self.source[self.at..].starts_with(prefix)
    }

    fn skip_comment(&mut self) {
        match self.source[self.at..].find("-->") {
            Some(offset) => self.at += offset + 3,
            None => self.at = self.bytes.len(),
        }
    }

    fn skip_to(&mut self, byte: u8) {
        while self.at < self.bytes.len() && self.bytes[self.at] != byte {
            self.at += 1;
        }
        self.at = (self.at + 1).min(self.bytes.len());
    }

    fn read_text(&mut self) -> String {
        let start = self.at;
        while self.at < self.bytes.len() && self.bytes[self.at] != b'<' {
            self.at += 1;
        }
        self.source[start..self.at].to_string()
    }

    /// Everything up to the matching closing tag, taken literally.
    fn read_raw_text(&mut self, tag: &str) -> String {
        let closing = format!("</{tag}");
        let rest = &self.source[self.at..];
        let end = match find_ignoring_case(rest, &closing) {
            Some(offset) => self.at + offset,
            None => self.bytes.len(),
        };
        let text = self.source[self.at..end].to_string();
        self.at = end;
        text
    }

    fn read_closing_tag(&mut self) -> String {
        self.at += 2;
        let start = self.at;
        while self.at < self.bytes.len() && !is_name_end(self.bytes[self.at]) {
            self.at += 1;
        }
        let name = self.source[start..self.at].to_ascii_lowercase();
        self.skip_to(b'>');
        name
    }

    /// Returns the element and whether the tag closed itself.
    fn read_open_tag(&mut self) -> Option<(Element, bool)> {
        let mark = self.at;
        self.at += 1;

        let start = self.at;
        while self.at < self.bytes.len() && !is_name_end(self.bytes[self.at]) {
            self.at += 1;
        }
        let tag = self.source[start..self.at].to_ascii_lowercase();
        if tag.is_empty() {
            self.at = mark;
            return None;
        }

        let mut attributes = Vec::new();
        let mut self_closing = false;

        loop {
            self.skip_whitespace();
            if self.at >= self.bytes.len() {
                break;
            }
            match self.bytes[self.at] {
                b'>' => {
                    self.at += 1;
                    break;
                }
                b'/' => {
                    self_closing = true;
                    self.at += 1;
                }
                _ => match self.read_attribute() {
                    Some(attribute) => attributes.push(attribute),
                    // Nothing consumable here; step over it rather than spin.
                    None => self.at += 1,
                },
            }
        }

        Some((Element { tag, attributes, children: Vec::new() }, self_closing))
    }

    fn read_attribute(&mut self) -> Option<(String, String)> {
        let start = self.at;
        while self.at < self.bytes.len() && !is_attribute_name_end(self.bytes[self.at]) {
            self.at += 1;
        }
        if self.at == start {
            return None;
        }
        let name = self.source[start..self.at].to_ascii_lowercase();

        self.skip_whitespace();
        if self.at >= self.bytes.len() || self.bytes[self.at] != b'=' {
            // A bare attribute is present and empty: `<div hidden>`.
            return Some((name, String::new()));
        }
        self.at += 1;
        self.skip_whitespace();

        if self.at >= self.bytes.len() {
            return Some((name, String::new()));
        }

        let value = match self.bytes[self.at] {
            quote @ (b'"' | b'\'') => {
                self.at += 1;
                let value_start = self.at;
                while self.at < self.bytes.len() && self.bytes[self.at] != quote {
                    self.at += 1;
                }
                let raw = &self.source[value_start..self.at];
                self.at = (self.at + 1).min(self.bytes.len());
                raw
            }
            _ => {
                let value_start = self.at;
                while self.at < self.bytes.len() && !is_unquoted_value_end(self.bytes[self.at]) {
                    self.at += 1;
                }
                &self.source[value_start..self.at]
            }
        };

        Some((name, decode(value)))
    }

    fn skip_whitespace(&mut self) {
        while self.at < self.bytes.len() && self.bytes[self.at].is_ascii_whitespace() {
            self.at += 1;
        }
    }
}

fn find_ignoring_case(haystack: &str, needle: &str) -> Option<usize> {
    let lowered = haystack.to_ascii_lowercase();
    lowered.find(&needle.to_ascii_lowercase())
}

fn is_name_end(byte: u8) -> bool {
    byte.is_ascii_whitespace() || byte == b'>' || byte == b'/'
}

fn is_attribute_name_end(byte: u8) -> bool {
    byte.is_ascii_whitespace() || byte == b'=' || byte == b'>' || byte == b'/'
}

fn is_unquoted_value_end(byte: u8) -> bool {
    byte.is_ascii_whitespace() || byte == b'>'
}

/// The named entities this document format actually uses.
///
/// `render.rs` escapes with `&amp;`, `&lt;`, `&gt;` and `&quot;` and writes
/// every other character literally, so this list only has to cover those plus
/// what an assistant is likely to type by hand. The em dash matters most: it
/// separates an item from its nights on every shopping-list line, and that
/// line is the key candidates are matched by.
const ENTITIES: &[(&str, &str)] = &[
    ("amp", "&"),
    ("lt", "<"),
    ("gt", ">"),
    ("quot", "\""),
    ("apos", "'"),
    ("#39", "'"),
    ("nbsp", "\u{a0}"),
    ("mdash", "—"),
    ("ndash", "–"),
    ("hellip", "…"),
    ("middot", "·"),
    ("times", "×"),
    ("frac12", "½"),
    ("frac14", "¼"),
    ("frac34", "¾"),
    ("deg", "°"),
];

pub fn decode(text: &str) -> String {
    if !text.contains('&') {
        return text.to_string();
    }

    let mut out = String::with_capacity(text.len());
    let mut rest = text;

    while let Some(offset) = rest.find('&') {
        out.push_str(&rest[..offset]);
        rest = &rest[offset..];

        // An entity is short. Anything longer is an ampersand somebody typed.
        // The window is counted in chars, not bytes: `rest` may hold an em
        // dash, and slicing 12 bytes into one panics.
        let Some(end) = rest
            .char_indices()
            .take(12)
            .find(|(_, character)| *character == ';')
            .map(|(offset, _)| offset)
        else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };

        let name = &rest[1..end];
        let replacement = if let Some(digits) = name.strip_prefix("#x").or(name.strip_prefix("#X")) {
            u32::from_str_radix(digits, 16).ok().and_then(char::from_u32).map(String::from)
        } else if let Some(digits) = name.strip_prefix('#') {
            digits.parse::<u32>().ok().and_then(char::from_u32).map(String::from)
        } else {
            ENTITIES
                .iter()
                .find(|(entity, _)| entity.eq_ignore_ascii_case(name))
                .map(|(_, value)| (*value).to_string())
        };

        match replacement {
            Some(value) => {
                out.push_str(&value);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }

    out.push_str(rest);
    out
}

/// The inverse, for `render.rs`.
///
/// Only the four characters that change how markup is read. Everything else —
/// the em dash, the fractions, the household's own accented words — is written
/// as the UTF-8 it already is, because the document is served as UTF-8 and a
/// numeric entity for every non-ASCII character would triple the size of a
/// document that crosses the wire on every save.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            other => out.push(other),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn only(source: &str, attribute: &str) -> String {
        parse(source).find(attribute).expect("element not found").text()
    }

    #[test]
    fn reads_attributes_and_text() {
        let root = parse(r#"<div data-mp-day data-mp-date="2026-08-25">Tuesday</div>"#);
        let day = root.find("data-mp-day").expect("day");
        assert_eq!(day.attribute("data-mp-date"), Some("2026-08-25"));
        assert_eq!(day.text(), "Tuesday");
    }

    #[test]
    fn a_dropped_closing_tag_still_yields_the_tree() {
        // The inner div never closes. The outer one closing has to close it.
        let root = parse(
            r#"<div data-mp-day data-mp-date="2026-08-25"><div data-mp-meal="Dinner">Tacos</div>"#,
        );
        let day = root.find("data-mp-day").expect("day");
        assert_eq!(day.attribute("data-mp-date"), Some("2026-08-25"));
        assert_eq!(day.find_all("data-mp-meal").len(), 1);
    }

    #[test]
    fn a_stray_closing_tag_is_ignored() {
        let root = parse("</span><div data-mp-day>Monday</div></p>");
        assert_eq!(root.find("data-mp-day").expect("day").text(), "Monday");
    }

    #[test]
    fn entities_come_back_as_characters() {
        assert_eq!(
            only(r#"<li data-mp-item>8 oz cheddar &mdash; 2026-08-25</li>"#, "data-mp-item"),
            "8 oz cheddar — 2026-08-25"
        );
        assert_eq!(decode("&amp;&lt;&gt;&quot;&#39;&#x2014;"), "&<>\"'—");
        assert_eq!(decode("Ben & Jerry"), "Ben & Jerry");
    }

    #[test]
    fn style_and_script_hold_text_not_markup() {
        let root = parse("<style>.a > .b { content: '<' }</style><div data-mp-day>Monday</div>");
        assert_eq!(root.find("data-mp-day").expect("day").text(), "Monday");
    }

    #[test]
    fn whitespace_in_text_collapses() {
        let root = parse("<li data-mp-ingredient>\n   1.5 lb   chicken\n  thighs\n</li>");
        assert_eq!(root.find("data-mp-ingredient").expect("line").text(), "1.5 lb chicken thighs");
    }

    #[test]
    fn void_elements_do_not_swallow_their_siblings() {
        let root = parse(r#"<div data-mp-day><br><hr/><div data-mp-meal="Dinner">x</div></div>"#);
        assert_eq!(root.find("data-mp-day").expect("day").find_all("data-mp-meal").len(), 1);
    }

    #[test]
    fn single_quoted_and_bare_attributes_read() {
        let root = parse("<div data-mp-day data-mp-date='2026-08-25' hidden>x</div>");
        let day = root.find("data-mp-day").expect("day");
        assert_eq!(day.attribute("data-mp-date"), Some("2026-08-25"));
        assert_eq!(day.attribute("data-mp-day"), Some(""));
        assert!(day.has_attribute("hidden"));
    }

    #[test]
    fn escape_is_the_inverse_for_the_four_that_matter() {
        let awkward = r#"Ben & Jerry's <b>"best"</b> — 1½ cup"#;
        assert_eq!(decode(&escape(awkward)), awkward);
    }

    #[test]
    fn comments_and_doctype_are_skipped() {
        let root = parse("<!-- plantrify plan --><!DOCTYPE html><div data-mp-day>Monday</div>");
        assert_eq!(root.find("data-mp-day").expect("day").text(), "Monday");
    }
}
