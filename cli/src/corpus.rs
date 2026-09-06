//! Reading the folder.
//!
//! The corpus parser lives here and nowhere else. The MCP server never reads a
//! recipe — it runs commands and commits — which is what keeps the document
//! format defined in exactly one place despite the two languages. See ADR 0007.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::quantity::{parse_quantity, to_display_number, unit_named, Number, Unit};

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

pub struct Meal {
    pub name: String,
    /// One-based line of the `## <name>` heading, for error messages.
    pub line: usize,
    /// Absent when the meal feeds whatever its recipes feed.
    pub servings: Option<Number>,
    pub recipes: Vec<RecipeLink>,
}

pub struct Day {
    pub path: String,
    pub date: String,
    pub meals: Vec<Meal>,
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
    pub root: PathBuf,
    pub recipes: Vec<Recipe>,
    pub days: Vec<Day>,
    pub staples: Vec<String>,
    pub consumables: Vec<Consumable>,
    pub problems: Vec<Problem>,
    /// Serving-size checks that are advisory, not corruption. A day is still
    /// valid; the household just wants a look before it shops.
    pub warnings: Vec<Problem>,
    /// adults + children from `config/household.md`, or None when the household
    /// never answered — in which case the validator has no serving opinion.
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
        root: root.to_path_buf(),
        recipes: Vec::new(),
        days: Vec::new(),
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
    for path in documents(root, "meals") {
        if wanted.as_deref().is_some_and(|only| only != path) {
            continue;
        }
        read_day(root, &path, &mut corpus);
    }

    corpus.staples = read_staples(root);
    corpus.consumables = read_consumables(root);
    corpus.household_servings = read_household_servings(root, &mut corpus);

    if let Some(only) = wanted {
        // A path outside recipes/ and meals/ has no schema to check. README.md
        // and the pantry documents are ordinary markdown on purpose.
        let known = corpus.recipes.iter().any(|recipe| recipe.path == only)
            || corpus.days.iter().any(|day| day.path == only);
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

fn read_day(root: &Path, path: &str, corpus: &mut Corpus) {
    let Some(text) = read(root, path, corpus) else { return };
    let stem = path.trim_start_matches("meals/").trim_end_matches(".md");

    let filename_date = is_date(stem);
    if !filename_date {
        corpus.problems.push(Problem {
            file: path.to_string(),
            line: None,
            message: format!(
                "the filename is not a date. A day of meals is named for its date, as YYYY-MM-DD.md — `meals/2026-08-25.md`, not `meals/{stem}.md`."
            ),
        });
    }

    let Some(front) = front_matter(&text) else {
        corpus.problems.push(missing_front_matter(path, "day of meals", "date:"));
        return;
    };

    let date = field(&front, "date").unwrap_or_default();
    if date.is_empty() {
        corpus.problems.push(Problem {
            file: path.to_string(),
            line: None,
            message: "the front matter has no `date:`. A day of meals records its date, for example `date: 2026-08-25`.".to_string(),
        });
    } else if filename_date && date != stem {
        corpus.problems.push(Problem {
            file: path.to_string(),
            line: None,
            message: format!(
                "the filename says {stem} and the front matter date says {date}. The filename and the date must match — the filename is what keeps one day in one file."
            ),
        });
    }

    // The old one-dinner shape held `servings:` in the front matter. Now that
    // a day holds any number of meals, servings belongs to a meal — and a
    // leftover front-matter line would otherwise scale nothing and silently
    // under-buy. Fail it by name.
    if field(&front, "servings").is_some() {
        corpus.problems.push(Problem {
            file: path.to_string(),
            line: None,
            message: "the front matter has `servings:`, but servings belongs to a meal now. Move it under the `## <meal>` heading it feeds — a day can hold several meals, each feeding a different number of people.".to_string(),
        });
    }

    let meals = read_meals(root, path, &text, corpus);
    corpus.days.push(Day { path: path.to_string(), date, meals });
}

/// The meals a day holds, one per `## <name>` heading.
///
/// Links sit directly under their meal heading. An optional `servings:` line
/// says how many people that meal feeds. Anything else inside the meal is
/// prose and left alone, which is what lets a day carry notes.
fn read_meals(root: &Path, path: &str, text: &str, corpus: &mut Corpus) -> Vec<Meal> {
    let mut meals: Vec<Meal> = Vec::new();
    let mut current: Option<Meal> = None;

    for (index, raw) in text.lines().enumerate() {
        let line = raw.trim();
        let number = index + 1;

        if line.starts_with("## ") {
            if let Some(meal) = current.take() {
                meals.push(meal);
            }
            current = Some(Meal {
                name: line["## ".len()..].trim().to_string(),
                line: number,
                servings: None,
                recipes: Vec::new(),
            });
            continue;
        }

        // A title at any other level is a boundary: the day title above, or a
        // heading inside a meal's own prose.
        if line.starts_with('#') {
            if let Some(meal) = current.take() {
                meals.push(meal);
            }
            continue;
        }

        let Some(meal) = current.as_mut() else { continue };

        if let Some(value) = line.strip_prefix("servings:") {
            let value = value.trim();
            match crate::quantity::parse_number(value) {
                Some(parsed) if parsed > Number::from_integer(0) => {
                    meal.servings = Some(parsed);
                }
                _ => corpus.problems.push(Problem {
                    file: path.to_string(),
                    line: Some(number),
                    message: format!(
                        "cannot read `servings: {value}` in the meal `{}`. Servings is a whole number, for example `servings: 4`.",
                        meal.name
                    ),
                }),
            }
            continue;
        }

        let Some(link) = markdown_link(line) else { continue };
        let target = resolve(path, &link.1);
        if !root.join(&target).exists() {
            corpus.problems.push(Problem {
                file: path.to_string(),
                line: Some(number),
                message: format!(
                    "{target} is missing. This meal links to a recipe that is not in the folder — record it, or remove the link."
                ),
            });
        }
        meal.recipes.push(RecipeLink { name: link.0, target, line: number });
    }

    if let Some(meal) = current {
        meals.push(meal);
    }
    meals
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

/// Warn, never fail, when a meal feeds too few people or more than double the
/// household. A lighter meal than the whole household is ordinary (a weekday
/// breakfast for one), so these are advisory, not corruption.
///
/// The warning is emitted only for a day that is the change in front of the
/// agent right now — uncommitted, or touched by the latest commit — so a
/// standing plan whose Tuesday lunch serves one does not get re-flagged on
/// every later `mealplan validate` that has nothing to do with it. See
/// `changed_meal_files`.
pub fn check_servings(corpus: &mut Corpus) {
    let Some(expected) = corpus.household_servings else {
        return;
    };
    let twice = expected * Number::from_integer(2);
    let changed = changed_meal_files(&corpus.root);
    let mut warnings = Vec::new();

    for day in &corpus.days {
        // When git cannot say (a folder that is not a repository), warn about
        // every offending day rather than silently none of them.
        if let Some(changed) = &changed {
            if !changed.contains(day.path.as_str()) {
                continue;
            }
        }

        for meal in &day.meals {
            let Some(servings) = effective_servings(corpus, meal) else {
                continue;
            };

            if servings < expected {
                warnings.push(Problem {
                    file: day.path.clone(),
                    line: Some(meal.line),
                    message: format!(
                        "{} serves {}, too few for the household of {}. If everyone is eating, raise its `servings:`.",
                        meal.name,
                        to_display_number(servings),
                        to_display_number(expected)
                    ),
                });
            } else if servings > twice {
                warnings.push(Problem {
                    file: day.path.clone(),
                    line: Some(meal.line),
                    message: format!(
                        "{} serves {}, more than double the household of {}. Check that `servings:` is not a doubled recipe amount.",
                        meal.name,
                        to_display_number(servings),
                        to_display_number(expected)
                    ),
                });
            }
        }
    }

    corpus.warnings = warnings;
}

/// The meal files the agent is looking at right now: the ones with uncommitted
/// changes, plus the ones the latest commit touched.
///
/// `mealplan validate` is normally run straight after an edit, and the server
/// commits after every mutating command — so "the latest commit" is the edit
/// the agent just made, and uncommitted changes are the edit still in progress
/// inside this one command. Gating to those two keeps the warning attached to
/// what is being changed.
///
/// Returns `None` when git cannot say, which `check_servings` treats as "no
/// gating".
fn changed_meal_files(root: &Path) -> Option<HashSet<String>> {
    let status = Command::new("git")
        .current_dir(root)
        .args(["status", "--porcelain"])
        .output()
        .ok()?;
    if !status.status.success() {
        return None;
    }

    let last_commit = Command::new("git")
        .current_dir(root)
        .args(["diff-tree", "--no-commit-id", "--name-only", "--root", "-r", "HEAD"])
        .output()
        .ok()?;
    if !last_commit.status.success() {
        return None;
    }

    let mut files = HashSet::new();

    for line in String::from_utf8_lossy(&status.stdout).lines() {
        if line.len() < 4 {
            continue;
        }
        // Porcelain: "XY path", or "XY old -> new" for a rename. The path is
        // everything after the two status characters and the following space;
        // for a rename, the destination is the right side of the arrow.
        let path = line[3..].trim();
        let path = path.rsplit(" -> ").next().unwrap_or(path).trim();
        if path.starts_with("meals/") {
            files.insert(path.to_string());
        }
    }

    for line in String::from_utf8_lossy(&last_commit.stdout).lines() {
        let path = line.trim();
        if path.starts_with("meals/") {
            files.insert(path.to_string());
        }
    }

    Some(files)
}

/// What a meal feeds: its own `servings:` line, or — without one — what its
/// recipes feed. A meal with no recipes and no servings claims nothing, so it
/// is never checked.
fn effective_servings(corpus: &Corpus, meal: &Meal) -> Option<Number> {
    if let Some(servings) = meal.servings {
        return Some(servings);
    }
    meal.recipes
        .iter()
        .filter_map(|link| corpus.recipe(&link.target))
        .map(|recipe| recipe.servings)
        .max()
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

fn markdown_link(line: &str) -> Option<(String, String)> {
    let body = line.strip_prefix("- ")?;
    let rest = body.strip_prefix('[')?;
    let (name, rest) = rest.split_once("](")?;
    let target = rest.strip_suffix(')')?;
    Some((name.to_string(), target.to_string()))
}

/// "meals/2026-08-25.md" + "../recipes/x.md" -> "recipes/x.md".
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
