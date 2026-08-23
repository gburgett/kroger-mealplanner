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
      One shopping list for a range of nights, with the units added up and the
      pantry staples left out. Derived from the folder every time, never stored.

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
        Some("shopping-list") => {
            eprintln!("mealplan: `shopping-list` is not built yet.");
            ExitCode::from(2)
        }
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
