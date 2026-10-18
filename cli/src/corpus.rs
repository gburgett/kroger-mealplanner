//! Reading the folder.
//!
//! The corpus parser lives here and nowhere else. The MCP server never parses a
//! recipe — it lays the documents out and runs this — which is what keeps the
//! document format defined in exactly one place despite the two languages. See
//! ADR 0007 and ADR 0038.

use std::fs;
use std::path::Path;

use crate::quantity::{parse_quantity, unit_named, Number, Unit};

/// Something wrong with a document, named well enough to act on.
///
/// Error messages are the documentation here. An agent recovers from "line 7 of
/// recipes/chicken-tacos.md: expected `- <qty> [unit] <item>`". It cannot
/// recover from "invalid input".
pub struct Problem {
    pub file: String,
    pub line: Option<usize>,
    pub message: String,
}

impl Problem {
    pub fn render(&self) -> String {
        match self.line {
            Some(line) => format!("{}:{}: {}", self.file, line, self.message),
            None => format!("{}: {}", self.file, self.message),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Ingredient {
    pub quantity: Number,
    pub unit: Option<Unit>,
    pub item: String,
}

pub struct Recipe {
    /// Relative to the folder root, so it reads the way the agent typed it.
    pub path: String,
    pub name: String,
    pub servings: Number,
    pub ingredients: Vec<Ingredient>,
}

/// Whether a consumable is left off the shopping list right now.
///
/// The household (or, later, a background job — see ADR 0014) flips this by
/// hand. "Stocked" behaves like a staple; "NeedsRecheck" behaves like an
/// ordinary ingredient, which is what puts it back on the list.
#[derive(PartialEq, Eq)]
pub enum ConsumableStatus {
    Stocked,
    NeedsRecheck,
}

pub struct Consumable {
    pub item: String,
    pub status: ConsumableStatus,
}

pub struct Corpus {
    pub recipes: Vec<Recipe>,
    pub staples: Vec<String>,
    pub consumables: Vec<Consumable>,
    pub problems: Vec<Problem>,
    /// Advisory, not corruption: a meal plan's own checks add to these.
    pub warnings: Vec<Problem>,
    /// adults + children from `config/household.md`, or None when the household
    /// never answered — in which case a plan has no serving opinion.
    pub household_servings: Option<Number>,
}

impl Corpus {
    pub fn recipe(&self, path: &str) -> Option<&Recipe> {
        self.recipes.iter().find(|recipe| recipe.path == path)
    }
}

/// Load the whole folder, or one document inside it.
pub fn load(root: &Path, only: Option<&str>) -> Corpus {
    let mut corpus = Corpus {
        recipes: Vec::new(),
        staples: Vec::new(),
        consumables: Vec::new(),
        problems: Vec::new(),
        warnings: Vec::new(),
        household_servings: None,
    };

    let wanted: Option<String> = only.map(normalise);

    for path in documents(root, "recipes") {
        if wanted.as_deref().is_some_and(|only| only != path) {
            continue;
        }
        read_recipe(root, &path, &mut corpus);
    }

    corpus.staples = read_staples(root);
    corpus.consumables = read_consumables(root);
    corpus.household_servings = read_household_servings(root, &mut corpus);

    if let Some(only) = wanted {
        // A path outside recipes/ has no markdown schema to check. README.md
        // and the pantry documents are ordinary markdown on purpose, and a
        // meal plan is checked by `plan`.
        let known = corpus.recipes.iter().any(|recipe| recipe.path == only);
        if !known && !root.join(&only).exists() {
            corpus.problems.push(Problem {
                file: only,
                line: None,
                message: "there is no such file in the meal-plan folder.".to_string(),
            });
        }
    }

    corpus
}

fn normalise(path: &str) -> String {
    path.trim_start_matches("./").trim_start_matches('/').to_string()
}

fn documents(root: &Path, directory: &str) -> Vec<String> {
    let mut found: Vec<String> = match fs::read_dir(root.join(directory)) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.path().is_file())
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|name| name.ends_with(".md"))
            .map(|name| format!("{directory}/{name}"))
            .collect(),
        Err(_) => Vec::new(),
    };
    // The filename is the primary key, so sorting it is sorting the corpus.
    found.sort();
    found
}

// --- recipes ---------------------------------------------------------------

fn read_recipe(root: &Path, path: &str, corpus: &mut Corpus) {
    let Some(text) = read(root, path, corpus) else { return };
    let Some(front) = front_matter(&text) else {
        corpus.problems.push(missing_front_matter(path, "recipe", "name: and servings:"));
        return;
    };

    let name = field(&front, "name").unwrap_or_default();
    if name.is_empty() {
        corpus.problems.push(Problem {
            file: path.to_string(),
            line: None,
            message: "the front matter has no `name:`. A recipe is named so that a meal can link to it.".to_string(),
        });
    }

    let servings = match field(&front, "servings") {
        Some(raw) => match crate::quantity::parse_number(&raw) {
            Some(number) if number > Number::from_integer(0) => number,
            _ => {
                corpus.problems.push(Problem {
                    file: path.to_string(),
                    line: None,
                    message: format!("cannot read `servings: {raw}`. Servings is a whole number, for example `servings: 4`."),
                });
                Number::from_integer(4)
            }
        },
        None => {
            corpus.problems.push(Problem {
                file: path.to_string(),
                line: None,
                message: "the front matter has no `servings:`. The shopping list scales a recipe by it, for example `servings: 4`.".to_string(),
            });
            Number::from_integer(4)
        }
    };

    let mut ingredients = Vec::new();
    for (number, line) in section(&text, "Ingredients") {
        let Some(body) = line.trim().strip_prefix("- ") else { continue };
        match parse_ingredient(body) {
            Some(ingredient) => ingredients.push(ingredient),
            None => corpus.problems.push(Problem {
                file: path.to_string(),
                line: Some(number),
                message: format!(
                    "cannot read `- {body}`. An ingredient is one list item, `- <quantity> [unit] <item>` — for example `- 1.5 cup flour`, `- 1 1/2 cup flour` or `- 2 eggs`, where no unit means a count."
                ),
            }),
        }
    }

    corpus.recipes.push(Recipe { path: path.to_string(), name, servings, ingredients });
}

/// `<quantity> [unit] <item>`, where a missing unit means a count.
///
/// The unit is only a unit if it is one we know. That is what tells
/// "12 corn tortillas" from "1.5 lb boneless chicken thighs" without guessing.
pub fn parse_ingredient(body: &str) -> Option<Ingredient> {
    let words: Vec<&str> = body.split_whitespace().collect();
    let (quantity, used) = parse_quantity(&words)?;
    let rest = &words[used..];
    let (unit, rest) = match rest.first().and_then(|word| unit_named(word)) {
        Some(unit) => (Some(unit), &rest[1..]),
        None => (None, rest),
    };
    if rest.is_empty() {
        return None;
    }
    Some(Ingredient { quantity, unit, item: rest.join(" ") })
}

// --- days ------------------------------------------------------------------

fn read_staples(root: &Path) -> Vec<String> {
    // A missing file is fine: the household keeps nothing in.
    let Ok(text) = fs::read_to_string(root.join("pantry/staples.md")) else { return Vec::new() };
    text.lines()
        .filter_map(|line| line.trim().strip_prefix("- "))
        .map(|item| item.trim().to_ascii_lowercase())
        .filter(|item| !item.is_empty())
        .collect()
}

/// `- <item>: stocked` or `- <item>: needs recheck`.
///
/// A missing file, or a line with no status this program recognises, is fine:
/// the item is simply not tracked, and an untracked item is bought like any
/// ordinary ingredient. Buying something the household already has is a wasted
/// trip; buying nothing of something they ran out of is worse, so an
/// unreadable line defaults to "on the list" rather than "left out".
fn read_consumables(root: &Path) -> Vec<Consumable> {
    let Ok(text) = fs::read_to_string(root.join("pantry/consumables.md")) else { return Vec::new() };
    text.lines()
        .filter_map(|line| line.trim().strip_prefix("- "))
        .filter_map(|line| {
            let (item, status) = line.split_once(':')?;
            let status = match status.trim().to_ascii_lowercase().as_str() {
                "stocked" => ConsumableStatus::Stocked,
                "needs recheck" => ConsumableStatus::NeedsRecheck,
                _ => return None,
            };
            let item = item.trim().to_ascii_lowercase();
            if item.is_empty() {
                return None;
            }
            Some(Consumable { item, status })
        })
        .collect()
}

// --- household size ------------------------------------------------------

/// `adults:` and `children:` from `config/household.md`, summed.
///
/// `preferences/household.md` is prose and never parsed (ADR 0013); the one
/// machine-read household fact lives in its own document so the validator can
/// compare meal servings against it. An absent file, an absent front matter,
/// or two empty values is "never answered", which is an ordinary state — the
/// validator simply has no serving opinion.
fn read_household_servings(root: &Path, corpus: &mut Corpus) -> Option<Number> {
    let path = "config/household.md";
    let Ok(text) = fs::read_to_string(root.join(path)) else {
        return None;
    };
    let Some(front) = front_matter(&text) else {
        return None;
    };

    let adults = field(&front, "adults").map(|value| value.trim().to_string());
    let children = field(&front, "children").map(|value| value.trim().to_string());

    let adults_given = adults.as_deref().is_some_and(|value| !value.is_empty());
    let children_given = children.as_deref().is_some_and(|value| !value.is_empty());

    match (adults_given, children_given) {
        (false, false) => None,
        (true, false) | (false, true) => {
            let missing = if adults_given { "children" } else { "adults" };
            corpus.problems.push(Problem {
                file: path.to_string(),
                line: None,
                message: format!(
                    "the household size is half-written: no `{missing}:`. A family size is both `adults:` and `children:` — write both, or leave both empty."
                ),
            });
            None
        }
        (true, true) => {
            let adults_raw = adults.unwrap_or_default();
            let children_raw = children.unwrap_or_default();

            match (parse_count(&adults_raw), parse_count(&children_raw)) {
                (Some(adults), Some(children)) => {
                    let total = Number::from_integer(adults) + Number::from_integer(children);
                    if total > Number::from_integer(0) { Some(total) } else { None }
                }
                _ => {
                    let (key, seen) = if parse_count(&adults_raw).is_none() {
                        ("adults", &adults_raw)
                    } else {
                        ("children", &children_raw)
                    };
                    corpus.problems.push(Problem {
                        file: path.to_string(),
                        line: None,
                        message: format!(
                            "cannot read `{key}: {seen}`. `adults:` and `children:` are whole non-negative numbers, for example `adults: 2` and `children: 2`."
                        ),
                    });
                    None
                }
            }
        }
    }
}

/// A whole, non-negative count: "2". Not "2.5", not "two".
fn parse_count(raw: &str) -> Option<i128> {
    let text = raw.trim();
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

// --- reading documents -----------------------------------------------------

fn read(root: &Path, path: &str, corpus: &mut Corpus) -> Option<String> {
    match fs::read_to_string(root.join(path)) {
        Ok(text) => Some(text),
        Err(error) => {
            corpus.problems.push(Problem {
                file: path.to_string(),
                line: None,
                message: format!("cannot be read: {error}."),
            });
            None
        }
    }
}

fn missing_front_matter(path: &str, kind: &str, fields: &str) -> Problem {
    Problem {
        file: path.to_string(),
        line: None,
        message: format!(
            "the front matter is missing. A {kind} begins with a line of `---`, then {fields}, then another line of `---`."
        ),
    }
}

pub fn front_matter(text: &str) -> Option<String> {
    let rest = text.strip_prefix("---\n")?;
    let end = rest.find("\n---")?;
    Some(rest[..end].to_string())
}

pub fn field(front: &str, name: &str) -> Option<String> {
    for line in front.lines() {
        let Some((key, value)) = line.split_once(':') else { continue };
        if key.trim() == name {
            return Some(value.trim().to_string());
        }
    }
    None
}

/// The lines of a `## Heading` section, with their one-based line numbers.
///
/// Everything below the last known section is prose and is left alone. The
/// validator never rewrites a document, so Grandma's tortilla trick survives.
fn section<'a>(text: &'a str, heading: &str) -> Vec<(usize, &'a str)> {
    let mut inside = false;
    let mut found = Vec::new();
    for (index, line) in text.lines().enumerate() {
        if let Some(title) = line.trim().strip_prefix("## ") {
            inside = title.trim() == heading;
            continue;
        }
        if line.trim().starts_with('#') {
            inside = false;
            continue;
        }
        if inside {
            found.push((index + 1, line));
        }
    }
    found
}

pub fn is_date(text: &str) -> bool {
    let parts: Vec<&str> = text.split('-').collect();
    if parts.len() != 3 || parts[0].len() != 4 || parts[1].len() != 2 || parts[2].len() != 2 {
        return false;
    }
    let Ok(year) = parts[0].parse::<i32>() else { return false };
    let Ok(month) = parts[1].parse::<u32>() else { return false };
    let Ok(day) = parts[2].parse::<u32>() else { return false };
    if !(1..=12).contains(&month) || day < 1 {
        return false;
    }
    day <= days_in_month(year, month)
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ => {
            if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
                29
            } else {
                28
            }
        }
    }
}
