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
mod html;
mod json;
mod plan;
mod quantity;
mod render;
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

  mealplan plan start --from YYYY-MM-DD --to YYYY-MM-DD [--name NAME]
                      [--out PATH] [--json]
      Begin a meal plan for a range of dates and print it. Pre-filled with the
      days in the range, the household size from config/household.md, the shop
      from config/kroger.md, the household's own notes from
      preferences/household.md, and whatever those dates already hold in the
      most recent plan that overlaps them. Written to plans/<from>--<to>.html.
      Two plans may cover the same days; the second one needs --name, and the
      name goes in the filename so \"ls plans/\" tells them apart.

  mealplan plan save --path PATH [--regenerate SECTION]...
                     [--return whole|changed|none] [--json]
      Save the document on standard input, check it, do the arithmetic, and
      print it back. WHAT YOU WROTE IS KEPT: recipes/ seeds a plan and then
      stops overruling it, so an ingredient you struck stays struck and a line
      you added stays added. What this fills in is the gaps — a recipe with no
      ingredients yet gets them — and what it recomputes is the shopping list
      and any meal whose servings no longer match what its ingredients were
      scaled for. With no document on standard input it works on what is
      already saved, which is how a --regenerate costs one small call.
      --regenerate SECTION throws that section away and builds it again from
      recipes/. That is how an ingredient comes BACK: never retype it.
      --return changed prints only the sections this save altered.

  mealplan plan show --path PATH [--section SECTION]...
      Print a saved plan, or only the sections named.

  mealplan plan validate --path PATH [--json]
      Check one plan without saving it.

  mealplan plan shopping-list --path PATH --json
      The plan's shopping list as structure, for the Kroger and Walmart tools.
      Every line carries the text candidates are anchored to, its search term,
      whether the shop had nothing for it, and whatever products are already
      written under it.

  mealplan plan candidates --path PATH (--list|--attach|--sent|--cart-link)
                           [--json]
      How the Kroger and Walmart tools write to a plan. --list prints the same
      structure as `plan shopping-list` and changes nothing. The other three
      read a JSON payload on standard input and save the plan:

        --attach      {\"found\":{\"<line>\":[{\"id\",\"count\",\"description\"}]},
                       \"searches\":{\"<line>\":\"term\"},\"notFound\":[\"<line>\"]}
        --sent        {\"stamp\":\"...\"}     appends one send stamp
        --cart-link   {\"url\":\"...\"}       sets the Walmart cart link

      A line is named by its text, never by a number, so an edit somewhere
      else cannot misplace a block. A name no line reads any more is skipped
      and reported, never guessed at. An empty candidate list removes the
      block, which is how \"I was shown candidates and chose nothing\" is
      recorded.

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
        Some("plan") => plan_command(&root, &arguments[1..]),
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

fn plan_command(root: &PathBuf, arguments: &[String]) -> ExitCode {
    let Some(job) = arguments.first().map(String::as_str) else {
        eprintln!(
            "mealplan plan: say which job — start, save, show, validate, shopping-list \
             or candidates."
        );
        return ExitCode::from(2);
    };
    let rest = &arguments[1..];

    let mut from: Option<String> = None;
    let mut to: Option<String> = None;
    let mut name: Option<String> = None;
    let mut path: Option<String> = None;
    let mut out: Option<String> = None;
    let mut as_json = false;
    let mut regenerate: Vec<plan::Section> = Vec::new();
    let mut sections: Vec<plan::Section> = Vec::new();
    let mut returning = plan::Returning::Whole;
    let mut candidate_job: Option<plan::CandidateJob> = None;

    let mut index = 0;
    while index < rest.len() {
        let argument = rest[index].as_str();
        let mut value_for = |flag: &str, index: &mut usize| -> Option<String> {
            let value = rest.get(*index + 1).cloned();
            if value.is_some() {
                *index += 1;
            } else {
                eprintln!("mealplan plan {job}: {flag} needs a value.");
            }
            value
        };

        match argument {
            "--json" => as_json = true,
            "--from" => match value_for("--from", &mut index) {
                Some(value) => from = Some(value),
                None => return ExitCode::from(2),
            },
            "--to" => match value_for("--to", &mut index) {
                Some(value) => to = Some(value),
                None => return ExitCode::from(2),
            },
            "--name" => match value_for("--name", &mut index) {
                Some(value) => name = Some(value),
                None => return ExitCode::from(2),
            },
            "--path" => match value_for("--path", &mut index) {
                Some(value) => path = Some(value),
                None => return ExitCode::from(2),
            },
            "--out" => match value_for("--out", &mut index) {
                Some(value) => out = Some(value),
                None => return ExitCode::from(2),
            },
            "--regenerate" | "--section" => {
                let Some(value) = value_for(argument, &mut index) else {
                    return ExitCode::from(2);
                };
                match plan::parse_section(&value) {
                    Ok(section) => {
                        if argument == "--regenerate" {
                            regenerate.push(section)
                        } else {
                            sections.push(section)
                        }
                    }
                    Err(message) => {
                        eprintln!("mealplan plan {job}: {message}");
                        return ExitCode::from(2);
                    }
                }
            }
            "--list" | "--attach" | "--sent" | "--cart-link" => {
                let wanted = match argument {
                    "--list" => plan::CandidateJob::List,
                    "--attach" => plan::CandidateJob::Attach,
                    "--sent" => plan::CandidateJob::Sent,
                    _ => plan::CandidateJob::CartLink,
                };
                // Two jobs in one call would write the document twice and the
                // second write would be against a plan the first had changed.
                if let Some(already) = candidate_job {
                    eprintln!(
                        "mealplan plan {job}: {argument} and --{} are two jobs. Run one, then \
                         the other.",
                        match already {
                            plan::CandidateJob::List => "list",
                            plan::CandidateJob::Attach => "attach",
                            plan::CandidateJob::Sent => "sent",
                            plan::CandidateJob::CartLink => "cart-link",
                        }
                    );
                    return ExitCode::from(2);
                }
                candidate_job = Some(wanted);
            }
            "--return" => {
                let Some(value) = value_for("--return", &mut index) else {
                    return ExitCode::from(2);
                };
                returning = match value.as_str() {
                    "whole" => plan::Returning::Whole,
                    "changed" => plan::Returning::Changed,
                    "none" => plan::Returning::None,
                    other => {
                        eprintln!(
                            "mealplan plan {job}: --return takes `whole`, `changed` or `none`, \
                             not `{other}`. `changed` prints only the sections this save altered."
                        );
                        return ExitCode::from(2);
                    }
                };
            }
            other => {
                eprintln!("mealplan plan {job}: there is no `{other}` option.");
                return ExitCode::from(2);
            }
        }
        index += 1;
    }

    match job {
        "start" => {
            let (Some(from), Some(to)) = (from, to) else {
                eprintln!(
                    "mealplan plan start: --from and --to are both needed, and both take a date \
                     written as YYYY-MM-DD — for example `mealplan plan start --from 2026-08-24 \
                     --to 2026-08-30`."
                );
                return ExitCode::from(2);
            };
            for (flag, value) in [("--from", &from), ("--to", &to)] {
                if !corpus::is_date(value) {
                    eprintln!(
                        "mealplan plan start: {flag} {value} is not a date. A date is written as \
                         YYYY-MM-DD, for example 2026-08-25."
                    );
                    return ExitCode::from(2);
                }
            }
            if to < from {
                eprintln!(
                    "mealplan plan start: --to {to} is before --from {from}. The end date cannot \
                     come before the start date."
                );
                return ExitCode::from(2);
            }
            let request = plan::Start { from: &from, to: &to, name: name.as_deref() };
            ExitCode::from(plan::run_start(root, request, out.as_deref(), as_json))
        }
        "save" => {
            let Some(path) = path else {
                eprintln!(
                    "mealplan plan save: --path is needed, and names the plan to save — for \
                     example `--path plans/2026-08-24--2026-08-30.html`."
                );
                return ExitCode::from(2);
            };
            let posted = plan::read_stdin();
            ExitCode::from(plan::run_save(root, &path, posted, &regenerate, returning, as_json))
        }
        "show" | "validate" | "shopping-list" => {
            let Some(path) = path else {
                eprintln!("mealplan plan {job}: --path is needed, and names the plan.");
                return ExitCode::from(2);
            };
            ExitCode::from(match job {
                "show" => plan::run_show(root, &path, &sections),
                "validate" => plan::run_validate(root, &path, as_json),
                _ => plan::run_shopping_list(root, &path),
            })
        }
        "candidates" => {
            let Some(path) = path else {
                eprintln!(
                    "mealplan plan candidates: --path is needed, and names the plan whose \
                     shopping list the products belong to."
                );
                return ExitCode::from(2);
            };
            let Some(candidate_job) = candidate_job else {
                eprintln!(
                    "mealplan plan candidates: say which job — --list, --attach, --sent or \
                     --cart-link. All but --list read a JSON payload on standard input."
                );
                return ExitCode::from(2);
            };
            ExitCode::from(plan::run_candidates(root, &path, candidate_job, as_json))
        }
        other => {
            eprintln!(
                "mealplan plan: there is no `{other}` job. It takes start, save, show, validate, \
                 shopping-list and candidates."
            );
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
