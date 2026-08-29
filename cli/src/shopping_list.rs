//! `mealplan shopping-list --from DATE --to DATE [--include-staples]
//! [--include-consumables] [--out PATH] [--json]`
//!
//! Derived from the folder every time and never stored. Read the days in the
//! range, follow every meal's links, scale each recipe by that meal's servings
//! over the recipe's own, and add the quantities up with their units.
//!
//! A broken document stops the whole list. Quietly under-buying is the worst
//! outcome there is, because it is found at the store.
//!
//! `--out` writes the list to a file instead of printing it, and `--json`
//! prints the same list as structure. THE FILE IS STILL NOT A STORE. It is the
//! sheet of paper the Kroger products get written onto, and the server writes
//! them there. See ADR 0010: the CLI owns the document format and gains only
//! these two flags, because `mealplan --help` is documentation the agent reads,
//! so anything added here is public API.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use crate::corpus::{field, front_matter, load, Consumable, ConsumableStatus, Corpus, Day, Meal};
use crate::json;
use crate::quantity::{Measure, Number};
use crate::sections::{section_for, ORDER};

/// Where the store and the delivery choice live. Written by the server when
/// the household picks a store; read here, never written here.
const KROGER_CONFIG: &str = "config/kroger.md";

/// The one directory a list may be written to. See `check_out_path`.
const LISTS_DIRECTORY: &str = "shopping-lists/";

pub struct Request<'a> {
    pub from: &'a str,
    pub to: &'a str,
    pub include_staples: bool,
    pub include_consumables: bool,
    pub out: Option<&'a str>,
    pub json: bool,
}

/// One item, in one family of units, and the nights that need it.
struct Line {
    item: String,
    measure: Measure,
    nights: BTreeSet<String>,
    /// True when pantry/consumables.md still calls this item "needs recheck".
    /// Marked "(check)" on the rendered line rather than left out — see
    /// ADR 0016 — because nobody has confirmed the household is actually out.
    check: bool,
}

/// Why an ingredient did not reach the list.
#[derive(PartialEq, Eq, PartialOrd, Ord, Clone, Copy)]
enum LeftOutReason {
    Staple,
    Consumable,
}

impl LeftOutReason {
    fn noun(self) -> &'static str {
        match self {
            LeftOutReason::Staple => "staple",
            LeftOutReason::Consumable => "consumable",
        }
    }

    fn document(self) -> &'static str {
        match self {
            LeftOutReason::Staple => "pantry/staples.md",
            LeftOutReason::Consumable => "pantry/consumables.md",
        }
    }

    fn flag(self) -> &'static str {
        match self {
            LeftOutReason::Staple => "--include-staples",
            LeftOutReason::Consumable => "--include-consumables",
        }
    }
}

/// Which store the list was matched against, and how it is collected.
struct Store {
    id: String,
    modality: String,
}

pub fn run(root: &Path, request: Request) -> i32 {
    if let Some(out) = request.out {
        if let Err(message) = check_out_path(out) {
            eprintln!("{message}");
            return 2;
        }
    }

    let corpus = load(root, None);

    let days: Vec<&Day> = corpus
        .days
        .iter()
        .filter(|day| !day.date.is_empty())
        .filter(|day| day.date.as_str() >= request.from && day.date.as_str() <= request.to)
        .collect();

    // Only the documents this list is built from. A broken recipe nobody is
    // cooking this week is a problem for `mealplan validate`, not a reason to
    // refuse the shopping.
    let mut involved: Vec<&str> = days.iter().map(|day| day.path.as_str()).collect();
    for day in &days {
        for meal in &day.meals {
            for link in &meal.recipes {
                involved.push(link.target.as_str());
            }
        }
    }
    let blocking: Vec<&crate::corpus::Problem> = corpus
        .problems
        .iter()
        .filter(|problem| involved.contains(&problem.file.as_str()))
        .collect();
    if !blocking.is_empty() {
        for problem in &blocking {
            eprintln!("{}", problem.render());
        }
        eprintln!(
            "\nThe shopping list was not written. Buying too little is worse than an error, \
             because it is found at the store."
        );
        return 1;
    }

    let (lines, dropped) = if days.is_empty() {
        (Vec::new(), Vec::new())
    } else {
        gather(&corpus, &days, request.include_staples, request.include_consumables)
    };
    let store = read_store(root);

    let markdown = render_markdown(&request, &days, &lines, &dropped);

    if let Some(out) = request.out {
        let document = format!("{}{markdown}", front_matter_for(&request, &store));
        if let Err(message) = write_out(root, out, &document) {
            eprintln!("{message}");
            return 1;
        }
    } else if !request.json {
        print!("{markdown}");
    }

    // Standard output is either the list or the structure, never both: a reader
    // that got markdown with a JSON document stuck on the end could not parse
    // either of them.
    if request.json {
        println!("{}", render_json(&request, &store, &lines, &dropped));
    }

    0
}

// --- the document ----------------------------------------------------------

/// The front matter `--out` adds. `--from` and `--to` are on it so that the
/// server can re-derive the same list from the file alone, and the store is on
/// it because a price is a price at one store and nothing else says which.
fn front_matter_for(request: &Request, store: &Store) -> String {
    format!(
        "---\nfrom: {}\nto: {}\nstore: {}\nmodality: {}\n---\n\n",
        request.from, request.to, store.id, store.modality
    )
}

fn render_markdown(
    request: &Request,
    days: &[&Day],
    lines: &[Line],
    dropped: &[(String, LeftOutReason)],
) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "# Shopping list for {} to {}\n",
        request.from, request.to
    ));

    if days.is_empty() {
        out.push_str(&format!(
            "\nNo meals are planned between {} and {}.\n",
            request.from, request.to
        ));
        return out;
    }

    if lines.is_empty() && dropped.is_empty() {
        out.push_str("\nNothing to buy: the days in this range link to no recipes.\n");
        return out;
    }

    for section in ORDER {
        let in_section: Vec<&Line> = lines
            .iter()
            .filter(|line| section_for(&line.item) == *section)
            .collect();
        if in_section.is_empty() {
            continue;
        }
        out.push_str(&format!("\n## {section}\n\n"));
        for line in in_section {
            out.push_str(&format!("- {}\n", render_line(line)));
        }
    }

    let checked: Vec<&str> = lines
        .iter()
        .filter(|line| line.check)
        .map(|line| line.item.as_str())
        .collect();
    if !checked.is_empty() {
        let plural = checked.len() > 1;
        let (be, subject, need, object) =
            if plural { ("are", "they", "need", "them") } else { ("is", "it", "needs", "it") };
        out.push_str("\n## Check before buying\n\n");
        out.push_str(&format!(
            "{} {be} marked \"(check)\" above: pantry/consumables.md still says {subject} \
             {need} a recheck. Ask the household whether they already have {object} before \
             buying {object}. kroger_send_to_cart refuses to send this list while a \"(check)\" \
             line is on it — delete the line if they still have it, or remove \"(check)\" from \
             the line if they need it.\n",
            checked.join(", "),
        ));
    }

    if !dropped.is_empty() {
        out.push_str("\n## Left out\n\n");
        for reason in [LeftOutReason::Staple, LeftOutReason::Consumable] {
            let items: Vec<&str> = dropped
                .iter()
                .filter(|(_, item_reason)| *item_reason == reason)
                .map(|(item, _)| item.as_str())
                .collect();
            if items.is_empty() {
                continue;
            }
            let plural = items.len() > 1;
            let noun = if plural {
                format!("{}s", reason.noun())
            } else {
                format!("a {}", reason.noun())
            };
            out.push_str(&format!(
                "{} — {noun}, kept in the pantry from {}. Pass {} to buy {} anyway.\n",
                items.join(", "),
                reason.document(),
                reason.flag(),
                if plural { "them" } else { "it" },
            ));
        }
    }

    out
}

/// The literal suffix a "(check)" line ends with. `kroger_send_to_cart`
/// refuses to send while any line still carries it — see ADR 0016.
const CHECK_MARK: &str = " (check)";

/// One item line, without its `- `.
///
/// THE SERVER MATCHES CANDIDATE PRODUCTS TO THIS EXACT TEXT. It anchors on the
/// line rather than on a line number, so that an edit elsewhere in the file
/// cannot misplace a block. Changing the shape here changes that contract, and
/// `shopping-list --json` carries the same string so the two cannot drift.
fn render_line(line: &Line) -> String {
    let nights: Vec<&str> = line.nights.iter().map(String::as_str).collect();
    let mark = if line.check { CHECK_MARK } else { "" };
    format!("{} {} — {}{mark}", line.measure.render(), line.item, nights.join(", "))
}

// --- the structure ---------------------------------------------------------

/// What the server reads instead of parsing the markdown back.
///
/// Built with the writer in json.rs. No serialiser crate and no JSON PARSER:
/// nothing in this program ever reads JSON, which is what keeps the dependency
/// count at zero. See ADR 0003 and ADR 0010.
fn render_json(
    request: &Request,
    store: &Store,
    lines: &[Line],
    dropped: &[(String, LeftOutReason)],
) -> String {
    let sections: Vec<String> = ORDER
        .iter()
        .filter_map(|section| {
            let items: Vec<String> = lines
                .iter()
                .filter(|line| section_for(&line.item) == *section)
                .map(|line| {
                    let (quantity, unit) = line.measure.render_parts();
                    json::object(vec![
                        json::field("quantity", json::string(&quantity)),
                        json::field(
                            "unit",
                            match unit {
                                Some(unit) => json::string(unit),
                                None => json::null(),
                            },
                        ),
                        json::field("item", json::string(&line.item)),
                        json::field(
                            "nights",
                            json::array(
                                line.nights.iter().map(|night| json::string(night)).collect(),
                            ),
                        ),
                        json::field("line", json::string(&render_line(line))),
                    ])
                })
                .collect();
            if items.is_empty() {
                return None;
            }
            Some(json::object(vec![
                json::field("section", json::string(section)),
                json::field("items", json::array(items)),
            ]))
        })
        .collect();

    json::object(vec![
        json::field("from", json::string(request.from)),
        json::field("to", json::string(request.to)),
        json::field(
            "store",
            if store.id.is_empty() { json::null() } else { json::string(&store.id) },
        ),
        json::field("modality", json::string(&store.modality)),
        json::field("sections", json::array(sections)),
        json::field(
            "leftOut",
            json::array(
                dropped
                    .iter()
                    .map(|(item, reason)| {
                        json::object(vec![
                            json::field("item", json::string(item)),
                            json::field("reason", json::string(reason.noun())),
                        ])
                    })
                    .collect(),
            ),
        ),
    ])
}

// --- --out -----------------------------------------------------------------

/// Refuse a path that is not a document in `shopping-lists/`.
///
/// The sandbox already stops this reaching outside the mount, so this is not
/// the containment. It is so that `--out ../../etc/passwd` and `--out
/// recipes/chicken-tacos.md` fail by NAME, before anything is overwritten —
/// `--out` is the one flag in this program that destroys a file.
fn check_out_path(out: &str) -> Result<(), String> {
    let complaint = |why: &str| {
        Err(format!(
            "mealplan shopping-list: --out {out} {why} A list is written to \
             {LISTS_DIRECTORY}, for example `--out {LISTS_DIRECTORY}2026-08-25--2026-08-31.md`."
        ))
    };

    if out.starts_with('/') {
        return complaint("is an absolute path.");
    }
    if out.split('/').any(|part| part == "..") {
        return complaint("leaves the meal-plan folder.");
    }
    if !out.starts_with(LISTS_DIRECTORY) {
        return complaint(&format!("is not in the {LISTS_DIRECTORY} directory."));
    }
    if !out.ends_with(".md") {
        return complaint("is not a markdown document.");
    }
    Ok(())
}

fn write_out(root: &Path, out: &str, document: &str) -> Result<(), String> {
    let target = root.join(out);
    if let Some(parent) = target.parent() {
        if let Err(error) = fs::create_dir_all(parent) {
            return Err(format!(
                "mealplan shopping-list: cannot make {}: {error}.",
                parent.display()
            ));
        }
    }
    fs::write(&target, document)
        .map_err(|error| format!("mealplan shopping-list: cannot write --out {out}: {error}."))
}

/// The store from `config/kroger.md`, or an empty one.
///
/// No account and no store is an ordinary state, not an error: the list is
/// still worth having, it just carries no prices, because Kroger returns none
/// without a location.
fn read_store(root: &Path) -> Store {
    let text = fs::read_to_string(root.join(KROGER_CONFIG)).unwrap_or_default();
    let front = front_matter(&text).unwrap_or_default();
    Store {
        id: field(&front, "store").unwrap_or_default(),
        modality: match field(&front, "modality") {
            Some(modality) if !modality.is_empty() => modality,
            _ => "pickup".to_string(),
        },
    }
}

// --- gathering -------------------------------------------------------------

fn gather(
    corpus: &Corpus,
    days: &[&Day],
    include_staples: bool,
    include_consumables: bool,
) -> (Vec<Line>, Vec<(String, LeftOutReason)>) {
    let mut lines: Vec<Line> = Vec::new();
    let mut dropped: BTreeSet<(String, LeftOutReason)> = BTreeSet::new();

    for day in days {
        for meal in &day.meals {
            let servings = servings_for(corpus, meal);
            for link in &meal.recipes {
                let Some(recipe) = corpus.recipe(&link.target) else { continue };
                let factor = servings / recipe.servings;
                for ingredient in &recipe.ingredients {
                    if !include_staples && is_staple(&corpus.staples, &ingredient.item) {
                        dropped.insert((ingredient.item.clone(), LeftOutReason::Staple));
                        continue;
                    }
                    if !include_consumables && is_stocked(&corpus.consumables, &ingredient.item) {
                        dropped.insert((ingredient.item.clone(), LeftOutReason::Consumable));
                        continue;
                    }
                    let check = needs_recheck(&corpus.consumables, &ingredient.item);
                    let measure = Measure::of(ingredient.quantity, ingredient.unit).scaled(factor);
                    add(&mut lines, &ingredient.item, measure, &day.date, check);
                }
            }
        }
    }

    (lines, dropped.into_iter().collect())
}

/// What a meal feeds. A meal with no servings of its own feeds what its
/// recipes feed.
fn servings_for(corpus: &Corpus, meal: &Meal) -> Number {
    if let Some(servings) = meal.servings {
        return servings;
    }
    meal.recipes
        .iter()
        .filter_map(|link| corpus.recipe(&link.target))
        .map(|recipe| recipe.servings)
        .max()
        .unwrap_or_else(|| Number::from_integer(4))
}

/// Add to the line for this item and this family of units, or start one.
///
/// The family is part of the key, which is the whole of "incompatible units
/// stay on separate lines rather than being guessed at": 28 oz of tomatoes and
/// 4 tomatoes are two lines, because nothing in the folder says what a tomato
/// weighs.
fn add(lines: &mut Vec<Line>, item: &str, measure: Measure, night: &str, check: bool) {
    let key = item.to_ascii_lowercase();
    for line in lines.iter_mut() {
        if line.item.to_ascii_lowercase() == key {
            if let Some(combined) = line.measure.add(measure) {
                line.measure = combined;
                line.nights.insert(night.to_string());
                line.check = line.check || check;
                return;
            }
        }
    }
    let mut nights = BTreeSet::new();
    nights.insert(night.to_string());
    lines.push(Line { item: item.to_string(), measure, nights, check });
}

/// Whether the household always has this in.
fn is_staple(staples: &[String], item: &str) -> bool {
    matches_any(staples.iter(), item)
}

/// Whether the household still has plenty of this, per pantry/consumables.md.
///
/// A consumable with no matching line, or one marked "needs recheck" rather
/// than "stocked", is not left out — it is bought like any other ingredient.
fn is_stocked(consumables: &[Consumable], item: &str) -> bool {
    matches_any(
        consumables
            .iter()
            .filter(|consumable| consumable.status == ConsumableStatus::Stocked)
            .map(|consumable| &consumable.item),
        item,
    )
}

/// Whether pantry/consumables.md still calls this item "needs recheck" —
/// nobody has confirmed the household is actually out, so it is bought, but
/// marked "(check)" rather than bought silently. See ADR 0016.
fn needs_recheck(consumables: &[Consumable], item: &str) -> bool {
    matches_any(
        consumables
            .iter()
            .filter(|consumable| consumable.status == ConsumableStatus::NeedsRecheck)
            .map(|consumable| &consumable.item),
        item,
    )
}

/// Matched on whole words, so "flour" leaves out "flour" and "plain flour" but
/// not "flourless chocolate cake".
fn matches_any<'a>(names: impl Iterator<Item = &'a String>, item: &str) -> bool {
    let lowered = item.to_ascii_lowercase();
    let words: Vec<&str> = lowered
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect();
    names.into_iter().any(|name| {
        let name_words: Vec<&str> = name
            .split(|character: char| !character.is_ascii_alphanumeric())
            .filter(|word| !word.is_empty())
            .collect();
        !name_words.is_empty() && words.windows(name_words.len()).any(|window| window == name_words)
    })
}
