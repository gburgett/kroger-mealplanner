//! Reading the folder.
//!
//! The corpus parser lives here and nowhere else. The MCP server never reads a
//! recipe — it runs commands and commits — which is what keeps the document
//! format defined in exactly one place despite the two languages. See ADR 0007.

use std::fs;
use std::path::{Path, PathBuf};

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

pub struct RecipeLink {
    pub name: String,
    /// Normalised to a root-relative path: "../recipes/x.md" becomes
    /// "recipes/x.md", which is what the error message should say.
    pub target: String,
    pub line: usize,
}

pub struct Dinner {
    pub path: String,
    pub date: String,
    /// Absent when the dinner feeds whatever its recipes feed.
    pub servings: Option<Number>,
    pub recipes: Vec<RecipeLink>,
}

pub struct Corpus {
    pub root: PathBuf,
    pub recipes: Vec<Recipe>,
    pub dinners: Vec<Dinner>,
    pub staples: Vec<String>,
    pub problems: Vec<Problem>,
}

impl Corpus {
    pub fn recipe(&self, path: &str) -> Option<&Recipe> {
        self.recipes.iter().find(|recipe| recipe.path == path)
    }
}

/// Load the whole folder, or one document inside it.
pub fn load(root: &Path, only: Option<&str>) -> Corpus {
    let mut corpus = Corpus {
        root: root.to_path_buf(),
        recipes: Vec::new(),
        dinners: Vec::new(),
        staples: Vec::new(),
        problems: Vec::new(),
    };

    let wanted: Option<String> = only.map(normalise);

    for path in documents(root, "recipes") {
        if wanted.as_deref().is_some_and(|only| only != path) {
            continue;
        }
        read_recipe(root, &path, &mut corpus);
    }
    for path in documents(root, "dinners") {
        if wanted.as_deref().is_some_and(|only| only != path) {
            continue;
        }
        read_dinner(root, &path, &mut corpus);
    }

    corpus.staples = read_staples(root);

    if let Some(only) = wanted {
        // A path outside recipes/ and dinners/ has no schema to check. README.md
        // and pantry/staples.md are ordinary markdown on purpose.
        let known = corpus.recipes.iter().any(|recipe| recipe.path == only)
            || corpus.dinners.iter().any(|dinner| dinner.path == only);
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
            message: "the front matter has no `name:`. A recipe is named so that a dinner can link to it.".to_string(),
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

// --- dinners ---------------------------------------------------------------

fn read_dinner(root: &Path, path: &str, corpus: &mut Corpus) {
    let Some(text) = read(root, path, corpus) else { return };
    let stem = path.trim_start_matches("dinners/").trim_end_matches(".md");

    let filename_date = is_date(stem);
    if !filename_date {
        corpus.problems.push(Problem {
            file: path.to_string(),
            line: None,
            message: format!(
                "the filename is not a date. A dinner is named for its night, as YYYY-MM-DD.md — `dinners/2026-08-25.md`, not `dinners/{stem}.md`."
            ),
        });
    }

    let Some(front) = front_matter(&text) else {
        corpus.problems.push(missing_front_matter(path, "dinner", "date:"));
        return;
    };

    let date = field(&front, "date").unwrap_or_default();
    if date.is_empty() {
        corpus.problems.push(Problem {
            file: path.to_string(),
            line: None,
            message: "the front matter has no `date:`. A dinner records its night, for example `date: 2026-08-25`.".to_string(),
        });
    } else if filename_date && date != stem {
        corpus.problems.push(Problem {
            file: path.to_string(),
            line: None,
            message: format!(
                "the filename says {stem} and the front matter date says {date}. The filename and the date must match — the filename is what makes one dinner per night."
            ),
        });
    }

    let servings = field(&front, "servings").and_then(|raw| crate::quantity::parse_number(&raw));

    let mut recipes = Vec::new();
    for (number, line) in section(&text, "Recipes") {
        let Some(link) = markdown_link(line.trim()) else { continue };
        let target = resolve(path, &link.1);
        if !root.join(&target).exists() {
            corpus.problems.push(Problem {
                file: path.to_string(),
                line: Some(number),
                message: format!(
                    "{target} is missing. This dinner links to a recipe that is not in the folder — record it, or remove the link."
                ),
            });
        }
        recipes.push(RecipeLink { name: link.0, target, line: number });
    }

    corpus.dinners.push(Dinner { path: path.to_string(), date, servings, recipes });
}

// --- pantry ----------------------------------------------------------------

fn read_staples(root: &Path) -> Vec<String> {
    // A missing file is fine: the household keeps nothing in.
    let Ok(text) = fs::read_to_string(root.join("pantry/staples.md")) else { return Vec::new() };
    text.lines()
        .filter_map(|line| line.trim().strip_prefix("- "))
        .map(|item| item.trim().to_ascii_lowercase())
        .filter(|item| !item.is_empty())
        .collect()
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

fn front_matter(text: &str) -> Option<String> {
    let rest = text.strip_prefix("---\n")?;
    let end = rest.find("\n---")?;
    Some(rest[..end].to_string())
}

fn field(front: &str, name: &str) -> Option<String> {
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

fn markdown_link(line: &str) -> Option<(String, String)> {
    let body = line.strip_prefix("- ")?;
    let rest = body.strip_prefix('[')?;
    let (name, rest) = rest.split_once("](")?;
    let target = rest.strip_suffix(')')?;
    Some((name.to_string(), target.to_string()))
}

/// "dinners/2026-08-25.md" + "../recipes/x.md" -> "recipes/x.md".
fn resolve(from: &str, target: &str) -> String {
    let mut parts: Vec<&str> = from.split('/').collect();
    parts.pop();
    for piece in target.split('/') {
        match piece {
            "." | "" => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    parts.join("/")
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
