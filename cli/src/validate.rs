//! `mealplan validate [--json] [path]`
//!
//! Reports EVERY problem, not the first. An agent that fixes one thing and is
//! told about the next one is doing the validator's bookkeeping for it.

use std::path::Path;

use crate::corpus::{check_servings, load, Corpus};
use crate::json;
use crate::quantity::to_display_number;

pub fn run(root: &Path, only: Option<&str>, as_json: bool) -> i32 {
    let mut corpus = load(root, only);
    check_servings(&mut corpus);

    if as_json {
        println!("{}", describe(&corpus));
        return if corpus.problems.is_empty() { 0 } else { 1 };
    }

    if corpus.problems.is_empty() {
        for warning in &corpus.warnings {
            eprintln!("warning: {}", warning.render());
        }
        match only {
            Some(path) => println!("{path} is valid."),
            None => {
                let meals: usize = corpus.days.iter().map(|day| day.meals.len()).sum();
                println!(
                    "The meal plan folder is valid: {} recipes, {} days, {} meals.",
                    corpus.recipes.len(),
                    corpus.days.len(),
                    meals
                );
            }
        }
        return 0;
    }

    for problem in &corpus.problems {
        eprintln!("{}", problem.render());
    }
    for warning in &corpus.warnings {
        eprintln!("warning: {}", warning.render());
    }
    eprintln!(
        "\n{} problem{} found.",
        corpus.problems.len(),
        if corpus.problems.len() == 1 { "" } else { "s" }
    );
    1
}

/// What the parser read, so that nothing else has to parse a document to know.
fn describe(corpus: &Corpus) -> String {
    let recipes = corpus
        .recipes
        .iter()
        .map(|recipe| {
            json::object(vec![
                json::field("path", json::string(&recipe.path)),
                json::field("name", json::string(&recipe.name)),
                json::field("servings", json::string(&to_display_number(recipe.servings))),
                json::field(
                    "ingredients",
                    json::array(
                        recipe
                            .ingredients
                            .iter()
                            .map(|ingredient| {
                                json::object(vec![
                                    json::field(
                                        "quantity",
                                        json::string(&to_display_number(ingredient.quantity)),
                                    ),
                                    json::field(
                                        "unit",
                                        match ingredient.unit {
                                            Some(unit) => json::string(unit.canonical),
                                            None => json::null(),
                                        },
                                    ),
                                    json::field("item", json::string(&ingredient.item)),
                                ])
                            })
                            .collect(),
                    ),
                ),
            ])
        })
        .collect();

    let days = corpus
        .days
        .iter()
        .map(|day| {
            json::object(vec![
                json::field("path", json::string(&day.path)),
                json::field("date", json::string(&day.date)),
                json::field(
                    "meals",
                    json::array(
                        day.meals
                            .iter()
                            .map(|meal| {
                                json::object(vec![
                                    json::field("name", json::string(&meal.name)),
                                    json::field(
                                        "servings",
                                        match meal.servings {
                                            Some(servings) => json::string(&to_display_number(servings)),
                                            None => json::null(),
                                        },
                                    ),
                                    json::field(
                                        "recipes",
                                        json::array(
                                            meal.recipes
                                                .iter()
                                                .map(|link| {
                                                    json::object(vec![
                                                        json::field("name", json::string(&link.name)),
                                                        json::field("target", json::string(&link.target)),
                                                    ])
                                                })
                                                .collect(),
                                        ),
                                    ),
                                ])
                            })
                            .collect(),
                    ),
                ),
            ])
        })
        .collect();

    let problems = corpus
        .problems
        .iter()
        .map(|problem| {
            json::object(vec![
                json::field("file", json::string(&problem.file)),
                json::field(
                    "line",
                    match problem.line {
                        Some(line) => line.to_string(),
                        None => json::null(),
                    },
                ),
                json::field("message", json::string(&problem.message)),
            ])
        })
        .collect();

    let warnings = corpus
        .warnings
        .iter()
        .map(|warning| {
            json::object(vec![
                json::field("file", json::string(&warning.file)),
                json::field(
                    "line",
                    match warning.line {
                        Some(line) => line.to_string(),
                        None => json::null(),
                    },
                ),
                json::field("message", json::string(&warning.message)),
            ])
        })
        .collect();

    json::object(vec![
        json::field("valid", json::boolean(corpus.problems.is_empty())),
        json::field("recipes", json::array(recipes)),
        json::field("days", json::array(days)),
        json::field(
            "staples",
            json::array(corpus.staples.iter().map(|item| json::string(item)).collect()),
        ),
        json::field("problems", json::array(problems)),
        json::field("warnings", json::array(warnings)),
    ])
}
