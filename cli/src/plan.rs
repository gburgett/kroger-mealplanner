//! The meal-plan document: what it holds, and what a save does to it.
//!
//! ADR 0037. One document covers a range of dates and carries the shopping
//! list for that range inside it. `plans/2026-08-24--2026-08-30.html`, and
//! beside it `plans/2026-08-24--2026-08-30-birthday-week.html` when the same
//! week holds a second plan.
//!
//! # The plan is authored, not derived
//!
//! This is the part that is easy to get backwards. `recipes/` SEEDS a plan and
//! then stops overruling it. Once a meal carries its own ingredient lines,
//! those lines are the truth for that meal — the household struck the olives
//! from Wednesday, and Wednesday has no olives, while `recipes/pasta.md` still
//! has them, because they wanted to skip them tonight and not forever.
//!
//! A save therefore obeys five rules, in this order:
//!
//!   1. Overwrite from the post. What the assistant sent is what lands.
//!   2. Fill gaps. A recipe with no ingredient block gets one, from that
//!      recipe, scaled to the meal's servings, stamped with what it was scaled
//!      for.
//!   3. Rescale when the stamp disagrees. Change the servings and every line
//!      in the block scales by the ratio. This rescales a hand-edited block
//!      too, which is right: strike the olives, then double the meal, and you
//!      get double of what is left.
//!   4. Keep what the assistant wrote. Notes, prose, ad-hoc shopping lines and
//!      ingredient text are carried through unchanged.
//!   5. Unless a section is asked for by name. `--regenerate` discards that
//!      section and rebuilds it from source.
//!
//! Rule 5 is not a detail. Without it "put the olives back" makes the
//! assistant retype the line and scale it from memory, which is the failure
//! this binary exists to prevent.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

use crate::corpus::{self, Ingredient, Problem};
use crate::html;
use crate::quantity::{format_number, Measure, Number};
use num_traits::Zero;
use crate::sections;
use crate::shopping_list;

pub const DIRECTORY: &str = "plans";

// --- the model -------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct Plan {
    pub path: String,
    pub from: String,
    pub to: String,
    pub name: Option<String>,
    pub adults: Option<i64>,
    pub children: Option<i64>,
    pub store: String,
    pub modality: String,
    pub days: Vec<Day>,
    pub standing_notes: Vec<String>,
    /// Lines the household asked for that no recipe put on the list.
    pub adhoc: Vec<AdHoc>,
    /// Products written under a line by the retailer tools, keyed by the
    /// line's rendered text. Anchored on the text and not on a line number, so
    /// an edit elsewhere cannot misplace a block — the same contract the
    /// markdown list had.
    pub candidates: BTreeMap<String, Vec<Candidate>>,
    pub searches: BTreeMap<String, String>,
    pub not_found: BTreeSet<String>,
    pub sent: Vec<String>,
    pub cart_link: Option<String>,
    pub prose: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct Day {
    pub date: String,
    pub note: Option<String>,
    pub meals: Vec<Meal>,
}

#[derive(Debug, Clone)]
pub struct Meal {
    pub name: String,
    pub servings: Option<Number>,
    pub note: Option<String>,
    pub recipes: Vec<PlannedRecipe>,
}

#[derive(Debug, Clone)]
pub struct PlannedRecipe {
    /// Root-relative, `recipes/chicken-tacos.md`. Empty when the meal names a
    /// dish with no document behind it.
    pub path: String,
    pub title: String,
    /// `None` is a gap for rule 2 to fill. `Some` is authored, and rule 4
    /// keeps it.
    pub ingredients: Option<Block>,
}

#[derive(Debug, Clone)]
pub struct Block {
    pub for_servings: Option<Number>,
    pub lines: Vec<Line>,
}

#[derive(Debug, Clone)]
pub struct Line {
    /// Exactly what the document said. Kept so an unreadable line survives a
    /// save rather than being silently dropped.
    pub text: String,
    pub parsed: Option<Ingredient>,
}

#[derive(Debug, Clone)]
pub struct AdHoc {
    pub text: String,
}

#[derive(Debug, Clone)]
pub struct Candidate {
    pub id: String,
    pub count: String,
    pub description: String,
    /// As the shop states it: "8 oz", "2 lb", "" when the shop says nothing.
    pub size: String,
    /// The shop's price as a plain decimal — "5.49", never "$5.49" — so a
    /// total can be taken without reading money out of prose. Empty when the
    /// shop returned none. A price is a price AT ONE SHOP (ADR 0010), which is
    /// why it lives on the candidate and not on the item.
    pub price: String,
}

/// One line of the derived shopping list.
#[derive(Debug, Clone)]
pub struct ListLine {
    pub item: String,
    pub measure: Option<Measure>,
    pub nights: BTreeSet<String>,
    pub check: bool,
    pub adhoc: bool,
    pub section: String,
}

impl ListLine {
    /// The text candidates are matched by.
    ///
    /// THE RETAILER TOOLS MATCH PRODUCTS TO THIS EXACT TEXT, so it has to stay
    /// stable across a save: candidates attached to "1 lb ground beef — Mon"
    /// must still find that line after an unrelated edit somewhere else in the
    /// document. That is why a line is addressed by its text and never by a
    /// number.
    ///
    /// It happens to match `shopping_list::render_line` as well. That is not a
    /// contract — there is no markdown list left to carry candidates over
    /// from — and neither renderer has to follow the other.
    pub fn anchor(&self) -> String {
        let nights: Vec<&str> = self.nights.iter().map(String::as_str).collect();
        let mark = if self.check { " (check)" } else { "" };
        match &self.measure {
            Some(measure) if !nights.is_empty() => {
                format!("{} {} — {}{mark}", measure.render(), self.item, nights.join(", "))
            }
            Some(measure) => format!("{} {}{mark}", measure.render(), self.item),
            None => format!("{}{mark}", self.item),
        }
    }
}

// --- sections --------------------------------------------------------------

/// What `--regenerate` and `--return` name. Rule 5's vocabulary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Section {
    All,
    ShoppingList,
    StandingNotes,
    Day(String),
    Meal(String, String),
    Recipe(String, String, String),
}

pub const SECTION_HELP: &str = "\
A section is one of:

    all                                          rebuild everything from recipes/
    shopping-list                                drop ad-hoc lines and hand edits
    standing-notes                               re-copy preferences/household.md
    day:2026-08-26                               every meal that day
    meal:2026-08-26/Dinner                       that meal, from its recipes
    meal:2026-08-26/Dinner/recipes/pasta.md      one recipe inside that meal";

pub fn parse_section(text: &str) -> Result<Section, String> {
    match text {
        "all" => return Ok(Section::All),
        "shopping-list" => return Ok(Section::ShoppingList),
        "standing-notes" => return Ok(Section::StandingNotes),
        _ => {}
    }
    if let Some(date) = text.strip_prefix("day:") {
        if !corpus::is_date(date) {
            return Err(format!("`{date}` is not a date. A date is written as YYYY-MM-DD."));
        }
        return Ok(Section::Day(date.to_string()));
    }
    if let Some(rest) = text.strip_prefix("meal:") {
        let Some((date, rest)) = rest.split_once('/') else {
            return Err(format!(
                "`meal:{rest}` needs a date and a meal name, as `meal:2026-08-26/Dinner`."
            ));
        };
        if !corpus::is_date(date) {
            return Err(format!("`{date}` is not a date. A date is written as YYYY-MM-DD."));
        }
        return Ok(match rest.split_once('/') {
            Some((meal, recipe)) => {
                Section::Recipe(date.to_string(), meal.to_string(), recipe.to_string())
            }
            None => Section::Meal(date.to_string(), rest.to_string()),
        });
    }
    Err(format!("there is no `{text}` section.\n\n{SECTION_HELP}"))
}

impl Section {
    fn covers_meal(&self, date: &str, meal: &str) -> bool {
        match self {
            Section::All => true,
            Section::Day(wanted) => wanted == date,
            Section::Meal(wanted_date, wanted_meal) => wanted_date == date && wanted_meal == meal,
            Section::Recipe(wanted_date, wanted_meal, _) => {
                wanted_date == date && wanted_meal == meal
            }
            _ => false,
        }
    }

    fn covers_recipe(&self, date: &str, meal: &str, recipe: &str) -> bool {
        match self {
            Section::Recipe(wanted_date, wanted_meal, wanted_recipe) => {
                wanted_date == date && wanted_meal == meal && wanted_recipe == recipe
            }
            other => other.covers_meal(date, meal),
        }
    }
}

/// The section name a meal is addressed by, for `--return changed`.
pub fn meal_section(date: &str, meal: &str) -> String {
    format!("meal:{date}/{meal}")
}

// --- naming ----------------------------------------------------------------

pub fn slug(name: &str) -> String {
    let mut out = String::new();
    let mut hyphen = false;
    for character in name.chars() {
        if character.is_ascii_alphanumeric() {
            out.push(character.to_ascii_lowercase());
            hyphen = false;
        } else if !out.is_empty() && !hyphen {
            out.push('-');
            hyphen = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

pub fn path_for(from: &str, to: &str, name: Option<&str>) -> String {
    match name.map(slug).filter(|slug| !slug.is_empty()) {
        Some(slug) => format!("{DIRECTORY}/{from}--{to}-{slug}.html"),
        None => format!("{DIRECTORY}/{from}--{to}.html"),
    }
}

/// Every plan document in the folder, sorted — so `ls plans/` and this agree.
pub fn documents(root: &Path) -> Vec<String> {
    let mut found: Vec<String> = match fs::read_dir(root.join(DIRECTORY)) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.path().is_file())
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|name| name.ends_with(".html"))
            .map(|name| format!("{DIRECTORY}/{name}"))
            .collect(),
        Err(_) => Vec::new(),
    };
    found.sort();
    found
}

// --- reading a document ----------------------------------------------------

pub fn parse(path: &str, source: &str) -> Plan {
    let document = html::parse(source);
    let root = document
        .find("data-plantrify-mealplan")
        .cloned()
        .unwrap_or_else(|| document.clone());

    let mut plan = Plan {
        path: path.to_string(),
        from: root.attribute("data-from").unwrap_or_default().to_string(),
        to: root.attribute("data-to").unwrap_or_default().to_string(),
        name: root.attribute("data-name").filter(|v| !v.is_empty()).map(str::to_string),
        adults: root.attribute("data-adults").and_then(|v| v.parse().ok()),
        children: root.attribute("data-children").and_then(|v| v.parse().ok()),
        store: root.attribute("data-store").unwrap_or_default().to_string(),
        modality: match root.attribute("data-modality") {
            Some(modality) if !modality.is_empty() => modality.to_string(),
            _ => "pickup".to_string(),
        },
        days: Vec::new(),
        standing_notes: Vec::new(),
        adhoc: Vec::new(),
        candidates: BTreeMap::new(),
        searches: BTreeMap::new(),
        not_found: BTreeSet::new(),
        sent: Vec::new(),
        cart_link: None,
        prose: Vec::new(),
    };

    for day in root.find_all("data-mp-day") {
        let date = day.attribute("data-mp-date").unwrap_or_default().to_string();
        if date.is_empty() {
            continue;
        }
        let mut meals = Vec::new();
        for meal in day.find_all("data-mp-meal") {
            let name = meal.attribute("data-mp-meal").unwrap_or_default().to_string();
            if name.is_empty() {
                continue;
            }
            let mut recipes = Vec::new();
            for reference in meal.find_all("data-mp-recipe") {
                let block = reference.find("data-mp-ingredients").map(read_block);
                recipes.push(PlannedRecipe {
                    path: reference.attribute("data-mp-recipe").unwrap_or_default().to_string(),
                    title: reference
                        .attribute("data-mp-recipe-title")
                        .map(str::to_string)
                        .unwrap_or_else(|| {
                            reference
                                .find("data-mp-recipe-name")
                                .map(|name| name.text())
                                .unwrap_or_default()
                        }),
                    ingredients: block,
                });
            }
            meals.push(Meal {
                name,
                servings: meal.attribute("data-mp-servings").and_then(parse_number),
                note: meal.find("data-mp-note").map(|note| note.text()).filter(|t| !t.is_empty()),
                recipes,
            });
        }
        plan.days.push(Day {
            date,
            note: day.find("data-mp-day-note").map(|note| note.text()).filter(|t| !t.is_empty()),
            meals,
        });
    }

    if let Some(notes) = root.find("data-mp-standing-notes") {
        for paragraph in notes.find_all("data-mp-standing-note") {
            let text = paragraph.text();
            if !text.is_empty() {
                plan.standing_notes.push(text);
            }
        }
    }

    if let Some(list) = root.find("data-mp-shopping-list") {
        for item in list.find_all("data-mp-item") {
            let anchor = match item.attribute("data-mp-item") {
                Some(value) if !value.is_empty() => value.to_string(),
                _ => item
                    .find("data-mp-item-text")
                    .map(|text| text.text())
                    .unwrap_or_else(|| item.text()),
            };
            if anchor.is_empty() {
                continue;
            }
            if item.has_attribute("data-mp-adhoc") {
                plan.adhoc.push(AdHoc { text: anchor.clone() });
            }
            if item.has_attribute("data-mp-not-found") {
                plan.not_found.insert(anchor.clone());
            }
            if let Some(search) = item.attribute("data-mp-search").filter(|v| !v.is_empty()) {
                plan.searches.insert(anchor.clone(), search.to_string());
            }
            let found: Vec<Candidate> = item
                .find_all("data-mp-candidate")
                .into_iter()
                .filter_map(|candidate| {
                    let id = candidate.attribute("data-mp-candidate")?.to_string();
                    if id.is_empty() {
                        return None;
                    }
                    // Every field is an attribute. The element's text is the
                    // human's view — "Cheddar — 8 oz — $5.49" — and is never
                    // read back, so a price stays a number rather than money
                    // recovered out of prose.
                    Some(Candidate {
                        id,
                        count: candidate
                            .attribute("data-mp-count")
                            .filter(|v| !v.is_empty())
                            .unwrap_or("1")
                            .to_string(),
                        description: candidate
                            .attribute("data-mp-description")
                            .unwrap_or_default()
                            .to_string(),
                        size: candidate.attribute("data-mp-size").unwrap_or_default().to_string(),
                        price: candidate.attribute("data-mp-price").unwrap_or_default().to_string(),
                    })
                })
                .collect();
            if !found.is_empty() {
                plan.candidates.insert(anchor, found);
            }
        }
        for sent in list.find_all("data-mp-sent") {
            let text = sent.text();
            if !text.is_empty() {
                plan.sent.push(text);
            }
        }
        plan.cart_link = list
            .find("data-mp-cart-link")
            .and_then(|link| link.attribute("data-mp-cart-link").map(str::to_string))
            .filter(|link| !link.is_empty());
    }

    for prose in root.find_all("data-mp-prose") {
        let text = prose.text();
        if !text.is_empty() {
            plan.prose.push(text);
        }
    }

    plan
}

fn read_block(element: &html::Element) -> Block {
    Block {
        for_servings: element.attribute("data-mp-for-servings").and_then(parse_number),
        lines: element
            .find_all("data-mp-ingredient")
            .into_iter()
            .map(|line| {
                let text = match line.attribute("data-mp-ingredient") {
                    Some(value) if !value.is_empty() => value.to_string(),
                    _ => line.text(),
                };
                Line { parsed: corpus::parse_ingredient(&text), text }
            })
            .filter(|line| !line.text.is_empty())
            .collect(),
    }
}

fn parse_number(text: &str) -> Option<Number> {
    let words: Vec<&str> = text.split_whitespace().collect();
    crate::quantity::parse_quantity(&words).map(|(number, _)| number)
}

// --- saving ----------------------------------------------------------------

pub struct Saved {
    pub plan: Plan,
    pub list: Vec<ListLine>,
    pub left_out: Vec<(String, &'static str)>,
    pub problems: Vec<Problem>,
    pub warnings: Vec<Problem>,
    /// Section names this save altered, for `--return changed`.
    pub changed: BTreeSet<String>,
}

/// Apply the five rules and derive the list.
pub fn save(root: &Path, mut plan: Plan, regenerate: &[Section]) -> Saved {
    let corpus = corpus::load(root, None);
    let mut problems = Vec::new();
    let mut warnings = Vec::new();
    let mut changed: BTreeSet<String> = BTreeSet::new();

    plan.days.sort_by(|left, right| left.date.cmp(&right.date));

    // Rule 5, first: a section asked for back is emptied, so rule 2 refills it.
    for section in regenerate {
        match section {
            Section::StandingNotes | Section::All => {
                plan.standing_notes = read_standing_notes(root);
                changed.insert("standing-notes".to_string());
            }
            _ => {}
        }
        match section {
            Section::ShoppingList | Section::All => {
                plan.adhoc.clear();
                changed.insert("shopping-list".to_string());
            }
            _ => {}
        }
        for day in &mut plan.days {
            for meal in &mut day.meals {
                if !section.covers_meal(&day.date, &meal.name) {
                    continue;
                }
                let mut touched = false;
                for recipe in &mut meal.recipes {
                    if section.covers_recipe(&day.date, &meal.name, &recipe.path) {
                        recipe.ingredients = None;
                        touched = true;
                    }
                }
                if touched {
                    changed.insert(meal_section(&day.date, &meal.name));
                }
            }
        }
    }

    for day in &mut plan.days {
        if !plan.from.is_empty() && (day.date < plan.from || day.date > plan.to) {
            problems.push(Problem {
                file: plan.path.clone(),
                line: None,
                message: format!(
                    "{} is outside this plan's range of {} to {}. Start another plan for that \
                     week, or widen this one.",
                    day.date, plan.from, plan.to
                ),
            });
        }

        for meal in &mut day.meals {
            let servings = meal_servings(meal, &corpus);

            for recipe in &mut meal.recipes {
                let known = corpus.recipe(&recipe.path);

                match &mut recipe.ingredients {
                    // Rule 2 — fill the gap.
                    None => {
                        let Some(known) = known else {
                            // A gap that cannot be filled is the one case where
                            // a missing recipe stops the list being right.
                            problems.push(Problem {
                                file: plan.path.clone(),
                                line: None,
                                message: format!(
                                    "{} on {} points at {}, which is not in recipes/, and the \
                                     meal has no ingredients of its own — so it adds nothing to \
                                     the shopping list. Write the recipe, or list the \
                                     ingredients on the meal.",
                                    meal.name,
                                    day.date,
                                    if recipe.path.is_empty() { "no recipe" } else { &recipe.path }
                                ),
                            });
                            continue;
                        };
                        if recipe.title.is_empty() {
                            recipe.title = known.name.clone();
                        }
                        let factor = servings / known.servings;
                        recipe.ingredients = Some(Block {
                            for_servings: Some(servings),
                            lines: known
                                .ingredients
                                .iter()
                                .map(|ingredient| scale_line(ingredient, factor))
                                .collect(),
                        });
                        changed.insert(meal_section(&day.date, &meal.name));
                    }
                    // Rules 3 and 4 — keep it, and rescale only if the stamp
                    // disagrees with what the meal now serves.
                    Some(block) => {
                        if known.is_none() && !recipe.path.is_empty() {
                            warnings.push(Problem {
                                file: plan.path.clone(),
                                line: None,
                                message: format!(
                                    "{} on {} points at {}, which is no longer in recipes/. The \
                                     plan keeps the ingredients it was given, so the shopping \
                                     list is still right.",
                                    meal.name, day.date, recipe.path
                                ),
                            });
                        }
                        if recipe.title.is_empty() {
                            recipe.title = known
                                .map(|recipe| recipe.name.clone())
                                .unwrap_or_else(|| title_from_path(&recipe.path));
                        }
                        match block.for_servings {
                            Some(stamped) if stamped != servings && !stamped.is_zero() => {
                                let factor = servings / stamped;
                                for line in &mut block.lines {
                                    if let Some(ingredient) = &line.parsed {
                                        *line = scale_line(ingredient, factor);
                                    }
                                }
                                block.for_servings = Some(servings);
                                changed.insert(meal_section(&day.date, &meal.name));
                            }
                            None => block.for_servings = Some(servings),
                            _ => {}
                        }
                        for line in &block.lines {
                            if line.parsed.is_none() {
                                warnings.push(Problem {
                                    file: plan.path.clone(),
                                    line: None,
                                    message: format!(
                                        "{} on {}: \"{}\" is not `- <quantity> [unit] <item>`, so \
                                         it is kept as written and left off the shopping list.",
                                        meal.name, day.date, line.text
                                    ),
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    let (list, left_out) = derive(&plan, &corpus);

    // Any meal that moved moves the list with it, so `--return changed` has to
    // say so. An assistant that spliced back only the meal and kept a stale
    // list would be showing the household a plan the folder does not hold.
    if changed.iter().any(|name| name.starts_with("meal:")) {
        changed.insert("shopping-list".to_string());
    }

    Saved { plan, list, left_out, problems, warnings, changed }
}

fn title_from_path(path: &str) -> String {
    path.rsplit('/')
        .next()
        .unwrap_or(path)
        .trim_end_matches(".md")
        .split('-')
        .map(|word| {
            let mut characters = word.chars();
            match characters.next() {
                Some(first) => first.to_ascii_uppercase().to_string() + characters.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<String>>()
        .join(" ")
}

/// Scale one line, keeping the unit the recipe was written in.
///
/// Deliberately NOT `Measure::render`, which climbs the unit ladder: that is
/// right for a shopping list, where 28 oz reads better as 1.75 lb, and wrong
/// here. A recipe that says `24 oz marinara` means the jar, and a cook reading
/// `1.5 lb marinara` off their own meal plan has been told something they did
/// not write. A count still rounds up — you cannot cook with 1.5 eggs any more
/// than you can buy them.
fn scale_line(ingredient: &Ingredient, factor: Number) -> Line {
    let text = match ingredient.unit {
        Some(unit) => format!(
            "{} {} {}",
            format_number(ingredient.quantity * factor),
            unit.canonical,
            ingredient.item
        ),
        None => format!(
            "{} {}",
            Measure::of(ingredient.quantity, None).scaled(factor).render(),
            ingredient.item
        ),
    };
    Line { parsed: corpus::parse_ingredient(&text), text }
}

fn meal_servings(meal: &Meal, corpus: &corpus::Corpus) -> Number {
    if let Some(servings) = meal.servings {
        return servings;
    }
    meal.recipes
        .iter()
        .filter_map(|recipe| corpus.recipe(&recipe.path))
        .map(|recipe| recipe.servings)
        .max()
        .unwrap_or_else(|| Number::from_integer(4))
}

// --- the list --------------------------------------------------------------

/// The shopping list, from the DOCUMENT's ingredient blocks.
///
/// Not from `recipes/`. That is the whole of "the plan is authored, not
/// derived": the household's edits are in these blocks, and a list built from
/// the recipes again would undo every one of them.
fn derive(plan: &Plan, corpus: &corpus::Corpus) -> (Vec<ListLine>, Vec<(String, &'static str)>) {
    let mut lines: Vec<ListLine> = Vec::new();
    let mut dropped: BTreeSet<(String, &'static str)> = BTreeSet::new();

    for day in &plan.days {
        for meal in &day.meals {
            for recipe in &meal.recipes {
                let Some(block) = &recipe.ingredients else { continue };
                for line in &block.lines {
                    let Some(ingredient) = &line.parsed else { continue };
                    if shopping_list::is_staple(&corpus.staples, &ingredient.item) {
                        dropped.insert((ingredient.item.clone(), "staple"));
                        continue;
                    }
                    if shopping_list::is_stocked(&corpus.consumables, &ingredient.item) {
                        dropped.insert((ingredient.item.clone(), "consumable"));
                        continue;
                    }
                    let check = shopping_list::needs_recheck(&corpus.consumables, &ingredient.item);
                    let measure = Measure::of(ingredient.quantity, ingredient.unit);
                    add(&mut lines, &ingredient.item, Some(measure), &day.date, check);
                }
            }
        }
    }

    // Ad-hoc lines last, and never filtered. No recipe put them here — the
    // household asked for them by name, so a staple of the same name is not a
    // reason to drop one.
    for adhoc in &plan.adhoc {
        lines.push(ListLine {
            item: adhoc.text.clone(),
            measure: None,
            nights: BTreeSet::new(),
            check: false,
            adhoc: true,
            section: sections::section_for(&adhoc.text).to_string(),
        });
    }

    for line in &mut lines {
        if !line.adhoc {
            line.section = sections::section_for(&line.item).to_string();
        }
    }

    lines.sort_by(|left, right| {
        let order = |line: &ListLine| {
            sections::ORDER.iter().position(|name| *name == line.section).unwrap_or(usize::MAX)
        };
        order(left)
            .cmp(&order(right))
            .then(left.adhoc.cmp(&right.adhoc))
            .then(left.item.to_ascii_lowercase().cmp(&right.item.to_ascii_lowercase()))
    });

    (lines, dropped.into_iter().collect())
}

fn add(lines: &mut Vec<ListLine>, item: &str, measure: Option<Measure>, night: &str, check: bool) {
    let key = item.to_ascii_lowercase();
    if let Some(measure) = measure {
        for line in lines.iter_mut() {
            if line.item.to_ascii_lowercase() == key && !line.adhoc {
                if let Some(existing) = line.measure {
                    if let Some(combined) = existing.add(measure) {
                        line.measure = Some(combined);
                        line.nights.insert(night.to_string());
                        line.check = line.check || check;
                        return;
                    }
                }
            }
        }
    }
    let mut nights = BTreeSet::new();
    nights.insert(night.to_string());
    lines.push(ListLine {
        item: item.to_string(),
        measure,
        nights,
        check,
        adhoc: false,
        section: sections::OTHER.to_string(),
    });
}

// --- starting a plan -------------------------------------------------------

pub struct Start<'a> {
    pub from: &'a str,
    pub to: &'a str,
    pub name: Option<&'a str>,
}

/// Build a new plan, pre-populated with everything the folder already knows.
pub fn start(root: &Path, request: Start) -> Plan {
    let path = path_for(request.from, request.to, request.name);
    let household = read_household(root);
    let store = read_store(root);

    // Start from whatever these dates already hold, in the most recent plan
    // that overlaps them. "Plan next week" then begins from next week, and
    // "revise this week" begins from this week.
    let existing = latest_overlapping(root, request.from, request.to, &path);
    let mut days: Vec<Day> = Vec::new();
    for date in dates_between(request.from, request.to) {
        let meals = existing
            .as_ref()
            .and_then(|plan| plan.days.iter().find(|day| day.date == date))
            .map(|day| day.meals.clone())
            .unwrap_or_default();
        let note = existing
            .as_ref()
            .and_then(|plan| plan.days.iter().find(|day| day.date == date))
            .and_then(|day| day.note.clone());
        days.push(Day { date, note, meals });
    }

    Plan {
        path,
        from: request.from.to_string(),
        to: request.to.to_string(),
        name: request.name.map(str::to_string),
        adults: household.0,
        children: household.1,
        store: store.0,
        modality: store.1,
        days,
        standing_notes: read_standing_notes(root),
        adhoc: Vec::new(),
        candidates: BTreeMap::new(),
        searches: BTreeMap::new(),
        not_found: BTreeSet::new(),
        sent: Vec::new(),
        cart_link: None,
        prose: Vec::new(),
    }
}

fn latest_overlapping(root: &Path, from: &str, to: &str, skip: &str) -> Option<Plan> {
    documents(root)
        .into_iter()
        .filter(|path| path != skip)
        .filter_map(|path| {
            let source = fs::read_to_string(root.join(&path)).ok()?;
            let plan = parse(&path, &source);
            (plan.from <= to.to_string() && plan.to >= from.to_string()).then_some(plan)
        })
        .next_back()
}

/// The household's own prose, copied across so it is in front of them while
/// they plan. Never parsed — ADR 0013 — only carried.
fn read_standing_notes(root: &Path) -> Vec<String> {
    let Ok(text) = fs::read_to_string(root.join("preferences/household.md")) else {
        return Vec::new();
    };
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .filter(|line| !line.starts_with('#'))
        .map(|line| line.trim_start_matches("- ").to_string())
        .collect()
}

fn read_household(root: &Path) -> (Option<i64>, Option<i64>) {
    let Ok(text) = fs::read_to_string(root.join("config/household.md")) else {
        return (None, None);
    };
    let Some(front) = corpus::front_matter(&text) else { return (None, None) };
    (
        corpus::field(&front, "adults").and_then(|value| value.trim().parse().ok()),
        corpus::field(&front, "children").and_then(|value| value.trim().parse().ok()),
    )
}

fn read_store(root: &Path) -> (String, String) {
    let text = fs::read_to_string(root.join("config/kroger.md")).unwrap_or_default();
    let front = corpus::front_matter(&text).unwrap_or_default();
    (
        corpus::field(&front, "store").unwrap_or_default(),
        match corpus::field(&front, "modality") {
            Some(modality) if !modality.is_empty() => modality,
            _ => "pickup".to_string(),
        },
    )
}

impl Plan {
    pub fn household_servings(&self) -> Option<Number> {
        match (self.adults, self.children) {
            (None, None) => None,
            (adults, children) => Some(Number::from_integer(
                (adults.unwrap_or(0) + children.unwrap_or(0)) as i128,
            )),
        }
    }

    pub fn meal_count(&self) -> usize {
        self.days.iter().map(|day| day.meals.len()).sum()
    }

    pub fn title(&self) -> String {
        self.name.clone().unwrap_or_else(|| format!("{} to {}", self.from, self.to))
    }
}

/// Every ISO date from `from` to `to`, inclusive.
pub fn dates_between(from: &str, to: &str) -> Vec<String> {
    let mut dates = Vec::new();
    let Some(mut day) = civil(from) else { return dates };
    let Some(last) = civil(to) else { return dates };
    while day <= last {
        dates.push(iso(day));
        day += 1;
    }
    dates
}

/// Days since the epoch, by Howard Hinnant's civil_from_days, inverted. Here
/// rather than in a crate for the reason everything else in this binary is:
/// what ships inside the sandbox image is audited.
fn civil(date: &str) -> Option<i64> {
    if !corpus::is_date(date) {
        return None;
    }
    let year: i64 = date[0..4].parse().ok()?;
    let month: i64 = date[5..7].parse().ok()?;
    let day: i64 = date[8..10].parse().ok()?;

    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}

fn iso(days: i64) -> String {
    let days = days + 719_468;
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * shifted + 2) / 5 + 1;
    let month = if shifted < 10 { shifted + 3 } else { shifted - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    format!("{year:04}-{month:02}-{day:02}")
}

/// "Monday 24", for the heading over a day.
pub fn weekday_label(date: &str) -> String {
    const NAMES: &[&str] =
        &["Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday"];
    let Some(days) = civil(date) else { return date.to_string() };
    let name = NAMES[days.rem_euclid(7) as usize];
    let day = date[8..10].trim_start_matches('0');
    format!("{name} {day}")
}

pub fn format_servings(value: Number) -> String {
    format_number(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- `plan candidates --attach` -------------------------------------
    //
    // apply_attach holds every rule the retailer tools depend on, and it is
    // pure, so it is tested here rather than through the filesystem. The
    // scenarios in features/ drive the command itself.

    fn bare_plan() -> Plan {
        Plan {
            path: "plans/2026-08-24--2026-08-30.html".to_string(),
            from: "2026-08-24".to_string(),
            to: "2026-08-30".to_string(),
            name: None,
            adults: Some(2),
            children: Some(2),
            store: String::new(),
            modality: String::new(),
            days: Vec::new(),
            standing_notes: Vec::new(),
            adhoc: Vec::new(),
            candidates: BTreeMap::new(),
            searches: BTreeMap::new(),
            not_found: BTreeSet::new(),
            sent: Vec::new(),
            cart_link: None,
            prose: Vec::new(),
        }
    }

    const BEEF: &str = "1 lb ground beef — Mon";
    const OLIVES: &str = "8 oz olives — Wed";

    fn known() -> BTreeSet<String> {
        [BEEF.to_string(), OLIVES.to_string()].into_iter().collect()
    }

    fn attach(plan: &mut Plan, payload: &str) -> Vec<String> {
        let value = crate::json::parse(payload).expect("payload parses");
        apply_attach(plan, &value, &known())
    }

    #[test]
    fn candidates_attach_to_the_line_that_reads_the_anchor() {
        let mut plan = bare_plan();
        let skipped = attach(
            &mut plan,
            r#"{"found":{"1 lb ground beef — Mon":[
                 {"id":"0001","count":"2","description":"Ground Beef 93%"},
                 {"id":"0002","count":1,"description":"Ground Beef 80%"}]}}"#,
        );
        assert!(skipped.is_empty());
        let found = &plan.candidates[BEEF];
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].id, "0001");
        // A count written as a number is text in the document either way.
        assert_eq!(found[1].count, "1");
    }

    #[test]
    fn an_anchor_no_line_reads_is_skipped_and_named() {
        // Never guessed at: the household is waiting on those candidates, and
        // putting them under the wrong line is worse than saying nothing.
        let mut plan = bare_plan();
        let skipped = attach(
            &mut plan,
            r#"{"found":{"2 lb quinoa — Fri":[{"id":"0009","description":"Quinoa"}]}}"#,
        );
        assert_eq!(skipped, vec!["2 lb quinoa — Fri".to_string()]);
        assert!(plan.candidates.is_empty());
    }

    #[test]
    fn an_empty_candidate_list_removes_the_block() {
        // "I was shown candidates and chose nothing" is an outcome.
        let mut plan = bare_plan();
        attach(&mut plan, r#"{"found":{"8 oz olives — Wed":[{"id":"0003","description":"Olives"}]}}"#);
        assert!(plan.candidates.contains_key(OLIVES));

        attach(&mut plan, r#"{"found":{"8 oz olives — Wed":[]}}"#);
        assert!(!plan.candidates.contains_key(OLIVES));
    }

    #[test]
    fn not_found_and_candidates_are_never_both_true() {
        let mut plan = bare_plan();
        attach(&mut plan, r#"{"notFound":["8 oz olives — Wed"]}"#);
        assert!(plan.not_found.contains(OLIVES));

        // The shop stocks it after all — the mark goes when the products come.
        attach(&mut plan, r#"{"found":{"8 oz olives — Wed":[{"id":"0003","description":"Olives"}]}}"#);
        assert!(!plan.not_found.contains(OLIVES));
        assert!(plan.candidates.contains_key(OLIVES));

        // And the other way about.
        attach(&mut plan, r#"{"notFound":["8 oz olives — Wed"]}"#);
        assert!(plan.not_found.contains(OLIVES));
        assert!(!plan.candidates.contains_key(OLIVES));
    }

    #[test]
    fn a_search_term_is_written_and_an_empty_one_clears_it() {
        let mut plan = bare_plan();
        attach(&mut plan, r#"{"searches":{"1 lb ground beef — Mon":"ground beef"}}"#);
        assert_eq!(plan.searches.get(BEEF).map(String::as_str), Some("ground beef"));

        attach(&mut plan, r#"{"searches":{"1 lb ground beef — Mon":"   "}}"#);
        assert!(!plan.searches.contains_key(BEEF));
    }

    #[test]
    fn one_payload_can_do_all_three_and_reports_every_unknown_anchor_once() {
        let mut plan = bare_plan();
        let skipped = attach(
            &mut plan,
            r#"{"found":{"1 lb ground beef — Mon":[{"id":"0001","description":"Beef"}],
                        "2 lb quinoa — Fri":[{"id":"0009","description":"Quinoa"}]},
                "searches":{"2 lb quinoa — Fri":"quinoa"},
                "notFound":["8 oz olives — Wed","2 lb quinoa — Fri"]}"#,
        );
        assert_eq!(skipped, vec!["2 lb quinoa — Fri".to_string()]);
        assert!(plan.candidates.contains_key(BEEF));
        assert!(plan.not_found.contains(OLIVES));
    }

    #[test]
    fn size_and_price_come_across_as_fields() {
        // Price is a plain decimal, never "$5.49": an agent asked to keep the
        // bill under a number has to add these up, and money recovered out of
        // prose is money read wrong.
        let mut plan = bare_plan();
        attach(
            &mut plan,
            r#"{"found":{"1 lb ground beef — Mon":[
                 {"id":"0001","count":"2","description":"Kroger Ground Beef",
                  "size":"1 lb","price":"5.49"}]}}"#,
        );
        let candidate = &plan.candidates[BEEF][0];
        assert_eq!(candidate.size, "1 lb");
        assert_eq!(candidate.price, "5.49");
    }

    #[test]
    fn a_shop_that_states_no_size_or_price_leaves_them_empty() {
        let mut plan = bare_plan();
        attach(
            &mut plan,
            r#"{"found":{"1 lb ground beef — Mon":[{"id":"0001","description":"Beef"}]}}"#,
        );
        let candidate = &plan.candidates[BEEF][0];
        assert!(candidate.size.is_empty());
        assert!(candidate.price.is_empty());
    }

    #[test]
    fn a_candidate_with_no_id_is_dropped_rather_than_written_blank() {
        let mut plan = bare_plan();
        attach(
            &mut plan,
            r#"{"found":{"1 lb ground beef — Mon":[
                 {"description":"no id here"},{"id":"0001","description":"Beef"}]}}"#,
        );
        let found = &plan.candidates[BEEF];
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].id, "0001");
    }

    use super::*;

    #[test]
    fn dates_run_across_a_month_end() {
        let dates = dates_between("2026-08-30", "2026-09-02");
        assert_eq!(dates, ["2026-08-30", "2026-08-31", "2026-09-01", "2026-09-02"]);
    }

    #[test]
    fn a_leap_day_is_a_day() {
        assert_eq!(dates_between("2028-02-28", "2028-03-01").len(), 3);
    }

    #[test]
    fn weekdays_line_up_with_the_calendar() {
        assert_eq!(weekday_label("2026-08-24"), "Monday 24");
        assert_eq!(weekday_label("2026-08-30"), "Sunday 30");
    }

    #[test]
    fn a_name_becomes_a_slug_in_the_filename() {
        assert_eq!(path_for("2026-08-24", "2026-08-30", None), "plans/2026-08-24--2026-08-30.html");
        assert_eq!(
            path_for("2026-08-24", "2026-08-30", Some("Birthday Week!")),
            "plans/2026-08-24--2026-08-30-birthday-week.html"
        );
    }

    #[test]
    fn sections_read_the_way_they_are_written() {
        assert_eq!(parse_section("all").unwrap(), Section::All);
        assert_eq!(parse_section("shopping-list").unwrap(), Section::ShoppingList);
        assert_eq!(parse_section("day:2026-08-26").unwrap(), Section::Day("2026-08-26".into()));
        assert_eq!(
            parse_section("meal:2026-08-26/Dinner").unwrap(),
            Section::Meal("2026-08-26".into(), "Dinner".into())
        );
        assert_eq!(
            parse_section("meal:2026-08-26/Dinner/recipes/pasta.md").unwrap(),
            Section::Recipe("2026-08-26".into(), "Dinner".into(), "recipes/pasta.md".into())
        );
    }

    #[test]
    fn an_unknown_section_names_the_ones_that_exist() {
        let message = parse_section("tuesday").unwrap_err();
        assert!(message.contains("shopping-list"), "{message}");
        assert!(message.contains("meal:"), "{message}");
    }
}

// --- the commands ----------------------------------------------------------
//
// Exit codes match the rest of this binary: 0 done, 1 the folder has a problem,
// 2 the arguments do.

use std::io::{IsTerminal, Read};

pub enum Returning {
    Whole,
    Changed,
    None,
}

pub fn run_start(root: &Path, request: Start, out: Option<&str>, as_json: bool) -> u8 {
    let path = path_for(request.from, request.to, request.name);
    let destination = out.unwrap_or(&path).to_string();

    if let Err(message) = check_path(&destination) {
        eprintln!("mealplan plan start: {message}");
        return 2;
    }

    if root.join(&destination).exists() {
        eprintln!(
            "mealplan plan start: {destination} is already a plan for {} to {}. Two plans may \
             cover the same days, but they need different names — pass --name to say what makes \
             this one different, for example `--name \"cheap week\"`.",
            request.from, request.to
        );
        return 2;
    }

    let plan = start(root, request);
    let saved = save(root, plan, &[]);
    write_and_report(root, &destination, &saved, Returning::Whole, as_json)
}

pub fn run_save(
    root: &Path,
    path: &str,
    posted: Option<String>,
    regenerate: &[Section],
    returning: Returning,
    as_json: bool,
) -> u8 {
    if let Err(message) = check_path(path) {
        eprintln!("mealplan plan save: {message}");
        return 2;
    }

    let source = match posted {
        Some(source) => source,
        None => match fs::read_to_string(root.join(path)) {
            Ok(source) => source,
            Err(_) => {
                eprintln!(
                    "mealplan plan save: there is no {path} to save, and nothing was given on \
                     standard input. Start one with `mealplan plan start --from DATE --to DATE`."
                );
                return 2;
            }
        },
    };

    let plan = parse(path, &source);
    if plan.from.is_empty() || plan.to.is_empty() {
        eprintln!(
            "mealplan plan save: {path} is not a meal plan — it has no data-from and data-to on \
             its root element. Start one with `mealplan plan start --from DATE --to DATE`."
        );
        return 2;
    }

    let saved = save(root, plan, regenerate);
    write_and_report(root, path, &saved, returning, as_json)
}

pub fn run_show(root: &Path, path: &str, wanted: &[Section]) -> u8 {
    let Ok(source) = fs::read_to_string(root.join(path)) else {
        eprintln!("mealplan plan show: there is no {path}.");
        return 2;
    };
    if wanted.is_empty() {
        print!("{source}");
        return 0;
    }
    let saved = save(root, parse(path, &source), &[]);
    for (name, fragment) in crate::render::fragments(&Saved {
        changed: wanted.iter().filter_map(section_name).collect(),
        ..saved
    }) {
        println!("<!-- {name} -->");
        print!("{fragment}");
    }
    0
}

pub fn run_validate(root: &Path, path: &str, as_json: bool) -> u8 {
    let Ok(source) = fs::read_to_string(root.join(path)) else {
        eprintln!("mealplan plan validate: there is no {path}.");
        return 2;
    };
    let saved = save(root, parse(path, &source), &[]);
    report(&saved, as_json, None)
}

pub fn run_shopping_list(root: &Path, path: &str) -> u8 {
    let Ok(source) = fs::read_to_string(root.join(path)) else {
        eprintln!("mealplan plan shopping-list: there is no {path}.");
        return 2;
    };
    let saved = save(root, parse(path, &source), &[]);
    println!("{}", list_json(&saved));
    if saved.problems.is_empty() { 0 } else { 1 }
}

/// What `mealplan plan candidates` is asked to do. One document, one change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CandidateJob {
    /// Print the list and its retailer state, and change nothing.
    List,
    /// Attach candidates, search terms and not-found marks from the payload.
    Attach,
    /// Append one send stamp.
    Sent,
    /// Set the Walmart cart link.
    CartLink,
}

/// The retailer tools' way into the document.
///
/// ADR 0037 put every read and write of a plan in the CLI, and this is the
/// half the retailer tools need: `Mealplan.Shopping.Plan` builds a payload and
/// runs this, exactly as `Mealplan.Plan` runs `plan save`. The payload travels
/// on standard input, like a posted document, so nothing an assistant supplied
/// is ever interpolated into a command line.
///
/// THE ANCHOR IS THE KEY. Every map in the payload is keyed by
/// `ListLine::anchor()` — the line's rendered text — and never by a line
/// number, so an edit elsewhere in the document cannot misplace a block. An
/// anchor that is no longer on the list is skipped rather than guessed at, and
/// it is reported, because silently dropping candidates the household is
/// waiting for is the failure this command exists to avoid.
pub fn run_candidates(root: &Path, path: &str, job: CandidateJob, as_json: bool) -> u8 {
    if let Err(message) = check_path(path) {
        eprintln!("mealplan plan candidates: {message}");
        return 2;
    }
    let Ok(source) = fs::read_to_string(root.join(path)) else {
        eprintln!("mealplan plan candidates: there is no {path}.");
        return 2;
    };

    let mut plan = parse(path, &source);
    if plan.from.is_empty() || plan.to.is_empty() {
        eprintln!(
            "mealplan plan candidates: {path} is not a meal plan — it has no data-from and \
             data-to on its root element."
        );
        return 2;
    }

    if job == CandidateJob::List {
        let saved = save(root, plan, &[]);
        println!("{}", list_json(&saved));
        return 0;
    }

    let payload = match read_payload(job) {
        Ok(payload) => payload,
        Err(message) => {
            eprintln!("mealplan plan candidates: {message}");
            return 2;
        }
    };

    // The anchors that exist right now, derived from the document as it
    // stands. Computed before the change so an unknown anchor can be named.
    let known: BTreeSet<String> = save(root, plan.clone(), &[])
        .list
        .iter()
        .map(ListLine::anchor)
        .collect();

    let skipped = match job {
        CandidateJob::Attach => apply_attach(&mut plan, &payload, &known),
        CandidateJob::Sent => {
            match payload.get_str("stamp").map(str::to_string) {
                Some(stamp) if !stamp.trim().is_empty() => plan.sent.push(stamp),
                _ => {
                    eprintln!(
                        "mealplan plan candidates --sent: the payload needs a \"stamp\" string."
                    );
                    return 2;
                }
            }
            Vec::new()
        }
        CandidateJob::CartLink => {
            match payload.get_str("url").map(str::to_string) {
                Some(url) if !url.trim().is_empty() => plan.cart_link = Some(url),
                _ => {
                    eprintln!(
                        "mealplan plan candidates --cart-link: the payload needs a \"url\" string."
                    );
                    return 2;
                }
            }
            Vec::new()
        }
        CandidateJob::List => Vec::new(),
    };

    let saved = save(root, plan, &[]);
    let document = crate::render::document(&saved);
    let full = root.join(path);
    if let Some(parent) = full.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Err(error) = fs::write(&full, &document) {
        eprintln!("mealplan plan candidates: cannot write {path}: {error}");
        return 2;
    }

    if as_json {
        use crate::json;
        println!(
            "{}",
            json::object(vec![
                json::field("path", json::string(path)),
                json::field(
                    "skipped",
                    json::array(skipped.iter().map(|anchor| json::string(anchor)).collect()),
                ),
                json::field("list", list_json(&saved)),
            ])
        );
    } else {
        for anchor in &skipped {
            eprintln!("warning: no line reads `{anchor}` any more, so it was left alone.");
        }
    }
    0
}

/// Attach the payload to the plan. Returns the anchors it did not recognise.
fn apply_attach(
    plan: &mut Plan,
    payload: &crate::json::Value,
    known: &BTreeSet<String>,
) -> Vec<String> {
    let mut skipped = BTreeSet::new();

    if let Some(found) = payload.get("found").and_then(crate::json::Value::as_object) {
        for (anchor, candidates) in found {
            if !known.contains(anchor) {
                skipped.insert(anchor.clone());
                continue;
            }
            let read: Vec<Candidate> = candidates
                .as_array()
                .iter()
                .filter_map(|candidate| {
                    let id = candidate.get_str("id")?.to_string();
                    Some(Candidate {
                        id,
                        count: candidate
                            .get("count")
                            .and_then(crate::json::Value::as_text)
                            .unwrap_or_else(|| "1".to_string()),
                        description: candidate
                            .get_str("description")
                            .unwrap_or_default()
                            .to_string(),
                        size: candidate
                            .get("size")
                            .and_then(crate::json::Value::as_text)
                            .unwrap_or_default(),
                        price: candidate
                            .get("price")
                            .and_then(crate::json::Value::as_text)
                            .unwrap_or_default(),
                    })
                })
                .collect();

            // An empty list REMOVES the block. That is how the household
            // choosing nothing is recorded, and it is an outcome, not a
            // failure.
            if read.is_empty() {
                plan.candidates.remove(anchor);
            } else {
                // Candidates and "nothing was found" cannot both be true.
                plan.not_found.remove(anchor);
                plan.candidates.insert(anchor.clone(), read);
            }
        }
    }

    if let Some(searches) = payload.get("searches").and_then(crate::json::Value::as_object) {
        for (anchor, term) in searches {
            if !known.contains(anchor) {
                skipped.insert(anchor.clone());
                continue;
            }
            match term.as_text() {
                // A term the agent wrote by hand is the agent's (ADR 0036), so
                // an empty one clears ours rather than writing a blank line.
                Some(text) if !text.trim().is_empty() => {
                    plan.searches.insert(anchor.clone(), text);
                }
                _ => {
                    plan.searches.remove(anchor);
                }
            }
        }
    }

    for anchor in payload.get("notFound").map(crate::json::Value::as_array).unwrap_or_default() {
        let Some(anchor) = anchor.as_text() else { continue };
        if !known.contains(&anchor) {
            skipped.insert(anchor);
            continue;
        }
        plan.candidates.remove(&anchor);
        plan.not_found.insert(anchor);
    }

    skipped.into_iter().collect()
}

fn read_payload(job: CandidateJob) -> Result<crate::json::Value, String> {
    let source = read_stdin().unwrap_or_default();
    if source.trim().is_empty() {
        return Err(format!(
            "{} needs a JSON payload on standard input, and standard input was empty.",
            match job {
                CandidateJob::Attach => "--attach",
                CandidateJob::Sent => "--sent",
                CandidateJob::CartLink => "--cart-link",
                CandidateJob::List => "--list",
            }
        ));
    }
    crate::json::parse(&source)
        .map_err(|message| format!("the payload on standard input is not JSON: {message}"))
}

fn section_name(section: &Section) -> Option<String> {
    match section {
        Section::ShoppingList => Some("shopping-list".to_string()),
        Section::StandingNotes => Some("standing-notes".to_string()),
        Section::Meal(date, meal) => Some(meal_section(date, meal)),
        _ => None,
    }
}

/// A plan path is in `plans/` and ends in `.html`. Refused here rather than
/// discovered later, and the message says what a good one looks like.
fn check_path(path: &str) -> Result<(), String> {
    if path.starts_with('/') || path.contains("..") {
        return Err(format!(
            "{path} is not a path inside the meal-plan folder. A plan is written to \
             plans/<from>--<to>.html."
        ));
    }
    if !path.starts_with(&format!("{DIRECTORY}/")) {
        return Err(format!(
            "{path} is not in {DIRECTORY}/. A plan lives at plans/<from>--<to>.html, so that \
             `ls plans/` is the calendar."
        ));
    }
    if !path.ends_with(".html") {
        return Err(format!("{path} does not end in .html. A meal plan is an HTML document."));
    }
    Ok(())
}

fn write_and_report(
    root: &Path,
    path: &str,
    saved: &Saved,
    returning: Returning,
    as_json: bool,
) -> u8 {
    let document = crate::render::document(saved);
    let full = root.join(path);
    if let Some(parent) = full.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Err(error) = fs::write(&full, &document) {
        eprintln!("mealplan: cannot write {path}: {error}");
        return 2;
    }
    report(saved, as_json, Some((returning, document)))
}

fn report(saved: &Saved, as_json: bool, returned: Option<(Returning, String)>) -> u8 {
    let status = if saved.problems.is_empty() { 0 } else { 1 };

    if as_json {
        println!("{}", save_json(saved, returned.as_ref()));
        return status;
    }

    for warning in &saved.warnings {
        eprintln!("warning: {}", warning.render());
    }
    for problem in &saved.problems {
        eprintln!("{}", problem.render());
    }

    match returned {
        Some((Returning::Whole, document)) => print!("{document}"),
        Some((Returning::Changed, _)) => {
            for (name, fragment) in crate::render::fragments(saved) {
                println!("<!-- {name} -->");
                print!("{fragment}");
            }
        }
        _ => {}
    }

    if !saved.problems.is_empty() {
        eprintln!(
            "\n{} found in {}.",
            count_of(saved.problems.len(), "problem", "problems"),
            saved.plan.path
        );
    }
    status
}

fn count_of(value: usize, one: &str, many: &str) -> String {
    format!("{value} {}", if value == 1 { one } else { many })
}

fn save_json(saved: &Saved, returned: Option<&(Returning, String)>) -> String {
    use crate::json;
    let mut fields = vec![
        json::field("path", json::string(&saved.plan.path)),
        json::field("from", json::string(&saved.plan.from)),
        json::field("to", json::string(&saved.plan.to)),
        json::field("valid", json::boolean(saved.problems.is_empty())),
        json::field(
            "problems",
            json::array(saved.problems.iter().map(problem_json).collect()),
        ),
        json::field(
            "warnings",
            json::array(saved.warnings.iter().map(problem_json).collect()),
        ),
    ];

    match returned {
        Some((Returning::Whole, document)) => {
            fields.push(json::field("document", json::string(document)))
        }
        Some((Returning::Changed, _)) => fields.push(json::field(
            "changed",
            json::array(
                crate::render::fragments(saved)
                    .into_iter()
                    .map(|(name, fragment)| {
                        json::object(vec![
                            json::field("section", json::string(&name)),
                            json::field("html", json::string(&fragment)),
                        ])
                    })
                    .collect(),
            ),
        )),
        _ => {}
    }

    json::object(fields)
}

fn problem_json(problem: &Problem) -> String {
    use crate::json;
    json::object(vec![
        json::field("file", json::string(&problem.file)),
        json::field(
            "line",
            problem.line.map(|line| line.to_string()).unwrap_or_else(json::null),
        ),
        json::field("message", json::string(&problem.message)),
    ])
}

/// The list as structure, for the retailer tools.
fn list_json(saved: &Saved) -> String {
    use crate::json;
    json::object(vec![
        json::field("path", json::string(&saved.plan.path)),
        json::field("from", json::string(&saved.plan.from)),
        json::field("to", json::string(&saved.plan.to)),
        json::field("store", json::string(&saved.plan.store)),
        json::field("modality", json::string(&saved.plan.modality)),
        json::field(
            "items",
            json::array(
                saved
                    .list
                    .iter()
                    .map(|line| {
                        let anchor = line.anchor();
                        let (quantity, unit) = match line.measure {
                            Some(measure) => {
                                let (quantity, unit) = measure.render_parts();
                                (json::string(&quantity), unit.map(json::string).unwrap_or_else(json::null))
                            }
                            None => (json::null(), json::null()),
                        };
                        json::object(vec![
                            json::field("line", json::string(&anchor)),
                            json::field("item", json::string(&line.item)),
                            json::field("quantity", quantity),
                            json::field("unit", unit),
                            json::field("section", json::string(&line.section)),
                            json::field("adhoc", json::boolean(line.adhoc)),
                            json::field("check", json::boolean(line.check)),
                            json::field(
                                "notFound",
                                json::boolean(saved.plan.not_found.contains(&anchor)),
                            ),
                            json::field(
                                "search",
                                saved
                                    .plan
                                    .searches
                                    .get(&anchor)
                                    .map(|term| json::string(term))
                                    .unwrap_or_else(json::null),
                            ),
                            json::field(
                                "nights",
                                json::array(line.nights.iter().map(|n| json::string(n)).collect()),
                            ),
                            json::field(
                                "candidates",
                                json::array(
                                    saved
                                        .plan
                                        .candidates
                                        .get(&anchor)
                                        .map(|found| {
                                            found
                                                .iter()
                                                .map(|candidate| {
                                                    json::object(vec![
                                                        json::field("id", json::string(&candidate.id)),
                                                        json::field("count", json::string(&candidate.count)),
                                                        json::field(
                                                            "description",
                                                            json::string(&candidate.description),
                                                        ),
                                                        json::field(
                                                            "size",
                                                            json::string(&candidate.size),
                                                        ),
                                                        json::field(
                                                            "price",
                                                            json::string(&candidate.price),
                                                        ),
                                                    ])
                                                })
                                                .collect()
                                        })
                                        .unwrap_or_default(),
                                ),
                            ),
                        ])
                    })
                    .collect(),
            ),
        ),
        json::field(
            "sent",
            json::array(saved.plan.sent.iter().map(|stamp| json::string(stamp)).collect()),
        ),
        json::field(
            "cartLink",
            saved
                .plan
                .cart_link
                .as_ref()
                .map(|url| json::string(url))
                .unwrap_or_else(json::null),
        ),
        json::field(
            "leftOut",
            json::array(
                saved
                    .left_out
                    .iter()
                    .map(|(item, reason)| {
                        json::object(vec![
                            json::field("item", json::string(item)),
                            json::field("reason", json::string(reason)),
                        ])
                    })
                    .collect(),
            ),
        ),
    ])
}

/// The document the assistant posted, from standard input. Empty means "work
/// on what is already saved", which is what makes a regenerate one small call.
pub fn read_stdin() -> Option<String> {
    // A terminal never reaches end of file, so reading one would hang forever
    // waiting for a document nobody is typing. `mealplan plan save --path P`
    // run by hand IS a regenerate, and it has to return.
    if std::io::stdin().is_terminal() {
        return None;
    }
    let mut buffer = String::new();
    match std::io::stdin().read_to_string(&mut buffer) {
        Ok(0) => None,
        Ok(_) if buffer.trim().is_empty() => None,
        Ok(_) => Some(buffer),
        Err(_) => None,
    }
}

/// Fold every plan document's problems and warnings into a whole-folder check.
///
/// Returns how many plans were read, so `mealplan validate` can say so — the
/// count is what tells an agent the folder it is looking at has plans at all.
pub fn check_all(root: &Path, corpus: &mut corpus::Corpus) -> usize {
    let paths = documents(root);
    for path in &paths {
        let Ok(source) = fs::read_to_string(root.join(path)) else { continue };
        let saved = save(root, parse(path, &source), &[]);
        corpus.problems.extend(saved.problems);
        corpus.warnings.extend(saved.warnings);
    }
    paths.len()
}
