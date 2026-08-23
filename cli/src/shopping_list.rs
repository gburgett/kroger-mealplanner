//! `mealplan shopping-list --from DATE --to DATE [--include-staples]`
//!
//! Derived from the folder every time and never stored. Read the dinners in the
//! range, follow the links, scale each recipe by that night's servings over the
//! recipe's own, and add the quantities up with their units.
//!
//! A broken document stops the whole list. Quietly under-buying is the worst
//! outcome there is, because it is found at the store.

use std::collections::BTreeSet;
use std::path::Path;

use crate::corpus::{load, Corpus, Dinner};
use crate::quantity::{Measure, Number};
use crate::sections::{section_for, ORDER};

pub struct Request<'a> {
    pub from: &'a str,
    pub to: &'a str,
    pub include_staples: bool,
}

/// One item, in one family of units, and the nights that need it.
struct Line {
    item: String,
    measure: Measure,
    nights: BTreeSet<String>,
}

pub fn run(root: &Path, request: Request) -> i32 {
    let corpus = load(root, None);

    let dinners: Vec<&Dinner> = corpus
        .dinners
        .iter()
        .filter(|dinner| !dinner.date.is_empty())
        .filter(|dinner| dinner.date.as_str() >= request.from && dinner.date.as_str() <= request.to)
        .collect();

    // Only the documents this list is built from. A broken recipe nobody is
    // cooking this week is a problem for `mealplan validate`, not a reason to
    // refuse the shopping.
    let mut involved: Vec<&str> = dinners.iter().map(|dinner| dinner.path.as_str()).collect();
    for dinner in &dinners {
        for link in &dinner.recipes {
            involved.push(link.target.as_str());
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

    println!("# Shopping list for {} to {}", request.from, request.to);

    if dinners.is_empty() {
        println!();
        println!(
            "No dinners are planned between {} and {}.",
            request.from, request.to
        );
        return 0;
    }

    let (lines, dropped) = gather(&corpus, &dinners, request.include_staples);

    if lines.is_empty() && dropped.is_empty() {
        println!();
        println!("Nothing to buy: the dinners in this range link to no recipes.");
        return 0;
    }

    for section in ORDER {
        let in_section: Vec<&Line> = lines
            .iter()
            .filter(|line| section_for(&line.item) == *section)
            .collect();
        if in_section.is_empty() {
            continue;
        }
        println!();
        println!("## {section}");
        println!();
        for line in in_section {
            let nights: Vec<&str> = line.nights.iter().map(String::as_str).collect();
            println!("- {} {} — {}", line.measure.render(), line.item, nights.join(", "));
        }
    }

    if !dropped.is_empty() {
        println!();
        println!("## Left out");
        println!();
        println!(
            "{} — {} kept in the pantry, from pantry/staples.md. Pass --include-staples to buy {} anyway.",
            dropped.join(", "),
            if dropped.len() == 1 { "a staple" } else { "staples" },
            if dropped.len() == 1 { "it" } else { "them" },
        );
    }

    0
}

fn gather(
    corpus: &Corpus,
    dinners: &[&Dinner],
    include_staples: bool,
) -> (Vec<Line>, Vec<String>) {
    let mut lines: Vec<Line> = Vec::new();
    let mut dropped: BTreeSet<String> = BTreeSet::new();

    for dinner in dinners {
        let servings = servings_for(corpus, dinner);
        for link in &dinner.recipes {
            let Some(recipe) = corpus.recipe(&link.target) else { continue };
            let factor = servings / recipe.servings;
            for ingredient in &recipe.ingredients {
                if !include_staples && is_staple(&corpus.staples, &ingredient.item) {
                    dropped.insert(ingredient.item.clone());
                    continue;
                }
                let measure = Measure::of(ingredient.quantity, ingredient.unit).scaled(factor);
                add(&mut lines, &ingredient.item, measure, &dinner.date);
            }
        }
    }

    (lines, dropped.into_iter().collect())
}

/// What a night feeds. A dinner with no servings of its own feeds what its
/// recipes feed.
fn servings_for(corpus: &Corpus, dinner: &Dinner) -> Number {
    if let Some(servings) = dinner.servings {
        return servings;
    }
    dinner
        .recipes
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
fn add(lines: &mut Vec<Line>, item: &str, measure: Measure, night: &str) {
    let key = item.to_ascii_lowercase();
    for line in lines.iter_mut() {
        if line.item.to_ascii_lowercase() == key {
            if let Some(combined) = line.measure.add(measure) {
                line.measure = combined;
                line.nights.insert(night.to_string());
                return;
            }
        }
    }
    let mut nights = BTreeSet::new();
    nights.insert(night.to_string());
    lines.push(Line { item: item.to_string(), measure, nights });
}

/// Whether the household always has this in.
///
/// Matched on whole words, so "flour" leaves out "flour" and "plain flour" but
/// not "flourless chocolate cake".
fn is_staple(staples: &[String], item: &str) -> bool {
    let lowered = item.to_ascii_lowercase();
    let words: Vec<&str> = lowered
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect();
    staples.iter().any(|staple| {
        let staple_words: Vec<&str> = staple
            .split(|character: char| !character.is_ascii_alphanumeric())
            .filter(|word| !word.is_empty())
            .collect();
        !staple_words.is_empty() && words.windows(staple_words.len()).any(|window| window == staple_words)
    })
}
