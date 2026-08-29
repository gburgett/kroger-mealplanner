//! `mealplan` — the two jobs in the meal plan that are not exploration.
//!
//! Everything else an agent does with this folder is bash: `ls`, `grep`,
//! `find`, `cat`, writing files. A command exists here only because an LLM
//! should not do the job from memory:
//!
//!   * unit-aware arithmetic across every recipe of every night in a range;
//!   * checking a corpus that is written freehand, before drift becomes
//!     corruption.
//!
//! Arguments are read by hand rather than by a crate, because the error
//! messages are the documentation and they have to name the argument at fault.

mod corpus;
mod json;
mod quantity;
mod sections;
mod shopping_list;
mod validate;

use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "\
mealplan — the two jobs that are not exploration

  mealplan validate [--json] [PATH]
      Check the meal-plan folder, or one document in it, against the format
      README.md describes. Reports every problem, naming the file and the line.
      --json prints what the parser read, rather than what is wrong with it.

  mealplan shopping-list --from YYYY-MM-DD --to YYYY-MM-DD [--include-staples]
                         [--include-consumables] [--out PATH] [--json]
      One shopping list for a range of nights, with the units added up, the
      pantry staples left out, and any pantry consumable left out while
      pantry/consumables.md still calls it stocked. A consumable still marked
      \"needs recheck\" is bought, but its line is marked \"(check)\" — the
      kroger_send_to_cart tool refuses to send while one is still on the list.
      Derived from the folder every time, never stored. --include-staples and
      --include-consumables buy them anyway, this once. --out writes it to a
      document in shopping-lists/ instead of printing it, with the range and
      the Kroger store from config/kroger.md in front matter. --json prints
      the same list as structure. Both together do both.

Run in the meal-plan folder. Everything else is bash.";

fn main() -> ExitCode {
    let arguments: Vec<String> = env::args().skip(1).collect();
    let root = match env::current_dir() {
        Ok(directory) => directory,
        Err(error) => {
            eprintln!("mealplan: cannot find the working directory: {error}");
            return ExitCode::from(2);
        }
    };

    match arguments.first().map(String::as_str) {
        Some("validate") => validate_command(&root, &arguments[1..]),
        Some("shopping-list") => shopping_list_command(&root, &arguments[1..]),
        Some("--help") | Some("-h") | Some("help") => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        Some(other) => {
            eprintln!("mealplan: there is no `{other}` command.\n\n{USAGE}");
            ExitCode::from(2)
        }
        None => {
            eprintln!("mealplan: say which job.\n\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn shopping_list_command(root: &PathBuf, arguments: &[String]) -> ExitCode {
    let mut from: Option<String> = None;
    let mut to: Option<String> = None;
    let mut include_staples = false;
    let mut include_consumables = false;
    let mut out: Option<String> = None;
    let mut as_json = false;

    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].as_str();
        match argument {
            "--include-staples" => include_staples = true,
            "--include-consumables" => include_consumables = true,
            "--json" => as_json = true,
            "--out" => {
                let Some(value) = arguments.get(index + 1) else {
                    eprintln!(
                        "mealplan shopping-list: --out needs a path, in shopping-lists/ — for \
                         example `--out shopping-lists/2026-08-25--2026-08-31.md`."
                    );
                    return ExitCode::from(2);
                };
                index += 1;
                out = Some(value.clone());
            }
            "--from" | "--to" => {
                let Some(value) = arguments.get(index + 1) else {
                    eprintln!("mealplan shopping-list: {argument} needs a date, written as YYYY-MM-DD.");
                    return ExitCode::from(2);
                };
                index += 1;
                if argument == "--from" { from = Some(value.clone()) } else { to = Some(value.clone()) }
            }
            other => {
                eprintln!(
                    "mealplan shopping-list: there is no `{other}` option. \
                     It takes --from YYYY-MM-DD, --to YYYY-MM-DD, --include-staples, \
                     --include-consumables, --out PATH and --json."
                );
                return ExitCode::from(2);
            }
        }
        index += 1;
    }

    let (Some(from), Some(to)) = (from, to) else {
        eprintln!(
            "mealplan shopping-list: --from and --to are both needed, and both take a date \
             written as YYYY-MM-DD — for example `mealplan shopping-list --from 2026-08-24 \
             --to 2026-08-30`."
        );
        return ExitCode::from(2);
    };

    for (flag, value) in [("--from", &from), ("--to", &to)] {
        if !corpus::is_date(value) {
            eprintln!(
                "mealplan shopping-list: {flag} {value} is not a date. A date is written as \
                 YYYY-MM-DD, for example 2026-08-25."
            );
            return ExitCode::from(2);
        }
    }

    if to < from {
        eprintln!(
            "mealplan shopping-list: --to {to} is before --from {from}. The end date cannot come \
             before the start date."
        );
        return ExitCode::from(2);
    }

    ExitCode::from(shopping_list::run(root, shopping_list::Request {
        from: &from,
        to: &to,
        include_staples,
        include_consumables,
        out: out.as_deref(),
        json: as_json,
    }) as u8)
}

fn validate_command(root: &PathBuf, arguments: &[String]) -> ExitCode {
    let mut as_json = false;
    let mut only: Option<String> = None;

    for argument in arguments {
        match argument.as_str() {
            "--json" => as_json = true,
            flag if flag.starts_with('-') => {
                eprintln!("mealplan validate: there is no `{flag}` option. Only `--json`.");
                return ExitCode::from(2);
            }
            path => {
                if only.is_some() {
                    eprintln!(
                        "mealplan validate: takes at most one path, and was given `{}` and `{path}`.",
                        only.unwrap()
                    );
                    return ExitCode::from(2);
                }
                only = Some(path.to_string());
            }
        }
    }

    ExitCode::from(validate::run(root, only.as_deref(), as_json) as u8)
}
