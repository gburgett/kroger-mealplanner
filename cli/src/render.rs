//! The canonical meal-plan document.
//!
//! Everything that lands in `plans/` is written here, from the model
//! `plan.rs` parsed. That is what ADR 0037 buys: the assistant cannot save a
//! document with a dropped tag, a day out of order, or a shopping list that
//! does not match the meals above it, because none of those survive a
//! round trip through the model.
//!
//! Two rules about the markup itself:
//!
//!   * Classes and ONE `<style>` block, never inline styles. The whole
//!     document crosses the wire on every save, and the design export this
//!     came from spent 24 KB on inline styles — about eight thousand tokens
//!     per edit, for nothing the household can see.
//!   * `data-mp-*` attributes carry the meaning; the tags and classes carry
//!     the look. A reader that wants the plan reads the attributes, so the
//!     look can change without changing what the document says.

use crate::html::escape;
use crate::plan::{self, ListLine, Plan, Saved};

/// The whole document, ready to write.
pub fn document(saved: &Saved) -> String {
    let plan = &saved.plan;
    let mut out = String::with_capacity(8192);

    out.push_str(&summary_comment(saved));
    out.push_str("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    out.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    out.push_str(&format!("<title>{}</title>\n", escape(&plan.title())));
    out.push_str(STYLE);
    out.push_str("</head>\n<body>\n");
    out.push_str(&root_open(plan));

    out.push_str(&header(saved));
    out.push_str(&issues(saved));
    out.push_str("<div class=\"days\">\n");
    for day in &plan.days {
        out.push_str(&day_section(plan, day));
    }
    out.push_str("</div>\n");
    out.push_str(&standing_notes(plan));
    out.push_str(&shopping_list(saved));

    for prose in &plan.prose {
        out.push_str(&format!("<p data-mp-prose>{}</p>\n", escape(prose)));
    }

    out.push_str(FOOTER);
    out.push_str("</div>\n</body>\n</html>\n");
    out
}

/// The sections a save changed, for `--return changed`.
pub fn fragments(saved: &Saved) -> Vec<(String, String)> {
    let plan = &saved.plan;
    let mut found = Vec::new();

    for name in &saved.changed {
        if name == "shopping-list" {
            found.push((name.clone(), shopping_list(saved)));
        } else if name == "standing-notes" {
            found.push((name.clone(), standing_notes(plan)));
        } else if let Some(rest) = name.strip_prefix("meal:") {
            if let Some((date, meal_name)) = rest.split_once('/') {
                if let Some(day) = plan.days.iter().find(|day| day.date == date) {
                    if let Some(meal) = day.meals.iter().find(|meal| meal.name == meal_name) {
                        found.push((name.clone(), meal_block(plan, day, meal)));
                    }
                }
            }
        }
    }

    found
}

/// Line 1 of every document, rewritten on every save so it cannot drift.
///
/// This is why there is no index file and no `mealplan plan list`:
/// `head -1 plans/*.html` is the index, and `ls plans/` is the calendar.
fn summary_comment(saved: &Saved) -> String {
    let plan = &saved.plan;
    let mut parts = vec![
        "plantrify plan".to_string(),
        format!("{}..{}", plan.from, plan.to),
    ];
    if let Some(name) = &plan.name {
        parts.push(name.clone());
    }
    parts.push(count(plan.days.len(), "day", "days"));
    parts.push(count(plan.meal_count(), "meal", "meals"));
    parts.push(count(saved.list.len(), "item", "items"));
    if !saved.problems.is_empty() {
        parts.push(count(saved.problems.len(), "problem", "problems"));
    }
    if !plan.sent.is_empty() {
        parts.push("sent to a cart".to_string());
    }
    format!("<!-- {} -->\n", parts.join(" · ").replace("--", "—"))
}

fn count(value: usize, one: &str, many: &str) -> String {
    format!("{value} {}", if value == 1 { one } else { many })
}

fn root_open(plan: &Plan) -> String {
    let mut attributes = vec![
        format!("data-plantrify-mealplan=\"v1\""),
        format!("data-from=\"{}\"", escape(&plan.from)),
        format!("data-to=\"{}\"", escape(&plan.to)),
    ];
    if let Some(name) = &plan.name {
        attributes.push(format!("data-name=\"{}\"", escape(name)));
    }
    if let Some(adults) = plan.adults {
        attributes.push(format!("data-adults=\"{adults}\""));
    }
    if let Some(children) = plan.children {
        attributes.push(format!("data-children=\"{children}\""));
    }
    if let Some(servings) = plan.household_servings() {
        attributes.push(format!(
            "data-household-servings=\"{}\"",
            plan::format_servings(servings)
        ));
    }
    if !plan.store.is_empty() {
        attributes.push(format!("data-store=\"{}\"", escape(&plan.store)));
    }
    attributes.push(format!("data-modality=\"{}\"", escape(&plan.modality)));
    format!("<div class=\"plan\" {}>\n", attributes.join(" "))
}

fn header(saved: &Saved) -> String {
    let plan = &saved.plan;
    let mut line = vec![
        count(plan.meal_count(), "meal", "meals"),
        count(saved.list.len(), "item", "items"),
    ];
    if let Some(servings) = plan.household_servings() {
        line.push(format!("serves {}", plan::format_servings(servings)));
    }
    format!(
        "<header class=\"top\">\n<div class=\"brand\">plantrify</div>\n<h1>{}</h1>\n\
         <p class=\"sub\">{} &middot; {}</p>\n</header>\n",
        escape(&plan.title()),
        escape(&format!("{} to {}", plan.from, plan.to)),
        escape(&line.join(" · "))
    )
}

fn issues(saved: &Saved) -> String {
    if saved.problems.is_empty() && saved.warnings.is_empty() {
        return String::new();
    }
    let mut out = String::from("<section data-mp-validation class=\"card issues\">\n");
    for problem in &saved.problems {
        out.push_str(&format!(
            "<p data-mp-problem data-mp-file=\"{}\"><span class=\"dot bad\"></span>{}</p>\n",
            escape(&problem.file),
            escape(&problem.message)
        ));
    }
    for warning in &saved.warnings {
        out.push_str(&format!(
            "<p data-mp-warning data-mp-file=\"{}\"><span class=\"dot warn\"></span>{}</p>\n",
            escape(&warning.file),
            escape(&warning.message)
        ));
    }
    out.push_str("</section>\n");
    out
}

fn day_section(plan: &Plan, day: &plan::Day) -> String {
    let mut out = format!(
        "<section data-mp-day data-mp-date=\"{}\" class=\"day\">\n<h2>{}</h2>\n<div class=\"card\">\n",
        escape(&day.date),
        escape(&plan::weekday_label(&day.date))
    );
    if day.meals.is_empty() && day.note.is_none() {
        out.push_str("<p class=\"empty\">Nothing planned yet.</p>\n");
    }
    for meal in &day.meals {
        out.push_str(&meal_block(plan, day, meal));
    }
    if let Some(note) = &day.note {
        out.push_str(&format!("<p data-mp-day-note class=\"note\">{}</p>\n", escape(note)));
    }
    out.push_str("</div>\n</section>\n");
    out
}

fn meal_block(_plan: &Plan, _day: &plan::Day, meal: &plan::Meal) -> String {
    let servings = meal
        .servings
        .map(|servings| format!(" data-mp-servings=\"{}\"", plan::format_servings(servings)))
        .unwrap_or_default();

    let mut out = format!(
        "<div data-mp-meal=\"{}\"{servings} class=\"meal\">\n<div class=\"mname\">{}</div>\n",
        escape(&meal.name),
        escape(&meal.name)
    );

    for recipe in &meal.recipes {
        let missing = if recipe.ingredients.is_none() { " data-mp-recipe-missing" } else { "" };
        out.push_str(&format!(
            "<div data-mp-recipe=\"{}\" data-mp-recipe-title=\"{}\"{missing} class=\"recipe\">\n\
             <div class=\"rname\">{}</div>\n",
            escape(&recipe.path),
            escape(&recipe.title),
            escape(&recipe.title)
        ));
        if let Some(block) = &recipe.ingredients {
            let stamp = block
                .for_servings
                .map(|servings| {
                    format!(" data-mp-for-servings=\"{}\"", plan::format_servings(servings))
                })
                .unwrap_or_default();
            out.push_str(&format!("<ul data-mp-ingredients{stamp} class=\"ing\">\n"));
            for line in &block.lines {
                out.push_str(&format!("<li data-mp-ingredient>{}</li>\n", escape(&line.text)));
            }
            out.push_str("</ul>\n");
        } else {
            out.push_str(
                "<p class=\"gap\">Not in the recipe box yet — nothing on the list for it.</p>\n",
            );
        }
        out.push_str("</div>\n");
    }

    if let Some(note) = &meal.note {
        out.push_str(&format!("<p data-mp-note class=\"note\">{}</p>\n", escape(note)));
    }
    out.push_str("</div>\n");
    out
}

fn standing_notes(plan: &Plan) -> String {
    if plan.standing_notes.is_empty() {
        return String::new();
    }
    let mut out = String::from(
        "<section data-mp-standing-notes data-mp-source=\"preferences/household.md\" \
         class=\"card notes\">\n<h2>The usual</h2>\n",
    );
    for note in &plan.standing_notes {
        out.push_str(&format!("<p data-mp-standing-note>{}</p>\n", escape(note)));
    }
    out.push_str("</section>\n");
    out
}

fn shopping_list(saved: &Saved) -> String {
    let plan = &saved.plan;
    let mut out = format!(
        "<section data-mp-shopping-list data-mp-from=\"{}\" data-mp-to=\"{}\" \
         data-mp-store=\"{}\" data-mp-modality=\"{}\" data-mp-lines=\"{}\" class=\"card list\">\n\
         <h2>Shopping list</h2>\n",
        escape(&plan.from),
        escape(&plan.to),
        escape(&plan.store),
        escape(&plan.modality),
        saved.list.len()
    );

    if saved.list.is_empty() {
        out.push_str("<p class=\"empty\">Nothing to buy yet.</p>\n");
    }

    let mut current: Option<&str> = None;
    for line in &saved.list {
        if current != Some(line.section.as_str()) {
            if current.is_some() {
                out.push_str("</ul>\n</div>\n");
            }
            out.push_str(&format!(
                "<div data-mp-aisle=\"{}\" class=\"aisle\">\n<div class=\"aname\">{}</div>\n<ul>\n",
                escape(&line.section),
                escape(&line.section)
            ));
            current = Some(line.section.as_str());
        }
        out.push_str(&item(saved, line));
    }
    if current.is_some() {
        out.push_str("</ul>\n</div>\n");
    }

    if !saved.left_out.is_empty() {
        let items: Vec<String> =
            saved.left_out.iter().map(|(item, _)| escape(item)).collect();
        out.push_str(&format!(
            "<p class=\"left-out\">Left out, because the pantry already has them: {}.</p>\n",
            items.join(", ")
        ));
    }

    for sent in &plan.sent {
        out.push_str(&format!("<p data-mp-sent class=\"sent\">{}</p>\n", escape(sent)));
    }
    if let Some(link) = &plan.cart_link {
        out.push_str(&format!(
            "<p><a data-mp-cart-link=\"{}\" href=\"{}\">Open the Walmart cart</a></p>\n",
            escape(link),
            escape(link)
        ));
    }

    out.push_str("</section>\n");
    out
}

fn item(saved: &Saved, line: &ListLine) -> String {
    let anchor = line.anchor();
    let mut attributes = format!("data-mp-item=\"{}\"", escape(&anchor));
    if line.adhoc {
        attributes.push_str(" data-mp-adhoc");
    }
    if line.check {
        attributes.push_str(" data-mp-check");
    }
    if saved.plan.not_found.contains(&anchor) {
        attributes.push_str(" data-mp-not-found");
    }
    if let Some(search) = saved.plan.searches.get(&anchor) {
        attributes.push_str(&format!(" data-mp-search=\"{}\"", escape(search)));
    }

    let mut out = format!(
        "<li {attributes}>\n<span data-mp-item-text>{}</span>\n",
        escape(&anchor)
    );

    if let Some(candidates) = saved.plan.candidates.get(&anchor) {
        out.push_str("<ul class=\"cand\">\n");
        for candidate in candidates {
            out.push_str(&format!(
                "<li data-mp-candidate=\"{}\" data-mp-count=\"{}\">{}</li>\n",
                escape(&candidate.id),
                escape(&candidate.count),
                escape(&candidate.description)
            ));
        }
        out.push_str("</ul>\n");
    }

    out.push_str("</li>\n");
    out
}

const FOOTER: &str = "<footer class=\"foot\">\n<span>plantrify</span>\n\
<span>Tell me what to change — swap a night, scale a meal, drop an ingredient, \
or say send it to the cart.</span>\n</footer>\n";

/// One style block, and a small one. See the note at the top of this file.
const STYLE: &str = r#"<style>
:root{--bg:#f1efe9;--card:#fff;--ink:#1c1c18;--soft:#8a877e;--line:#e4e1d9;--green:#2f6b45;--bad:#c0533a;--warn:#c69a2e}
@media(prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#17171a;--card:#212125;--ink:#ececea;--soft:#9b988f;--line:#31313a;--green:#7fbf99}}
:root[data-theme="dark"]{--bg:#17171a;--card:#212125;--ink:#ececea;--soft:#9b988f;--line:#31313a;--green:#7fbf99}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:400 16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
.plan{max-width:820px;margin:0 auto;padding:16px 16px 28px}
.brand{font:400 15px/1.2 Georgia,serif;color:var(--green);letter-spacing:.02em}
h1{font:700 clamp(24px,6vw,31px)/1.15 inherit;letter-spacing:-.02em;margin:2px 0 2px}
h2{font:600 12.5px/1 inherit;letter-spacing:.04em;text-transform:uppercase;color:var(--soft);margin:22px 4px 7px}
.sub{color:var(--soft);font-size:14px;margin:0}
.card{background:var(--card);border-radius:12px;overflow:hidden}
.day .card{padding:2px 0}
.meal{padding:11px 15px;border-top:.5px solid var(--line)}
.meal:first-child{border-top:0}
.mname{font-size:13px;color:var(--soft)}
.recipe{margin-top:3px}
.rname{font-size:16px}
.ing{margin:3px 0 0;padding-left:18px;color:var(--soft);font-size:14px}
.gap{color:var(--bad);font-size:13.5px;margin:2px 0 0}
.note{color:var(--soft);font-size:13.5px;margin:4px 0 0}
.empty{color:var(--soft);font-size:14px;padding:11px 15px;margin:0}
.issues p{display:flex;gap:10px;align-items:flex-start;padding:11px 15px;margin:0;border-top:.5px solid var(--line);font-size:14.5px}
.issues p:first-child{border-top:0}
.dot{width:7px;height:7px;border-radius:9px;flex:none;margin-top:7px;background:var(--soft)}
.dot.bad{background:var(--bad)}
.dot.warn{background:var(--warn)}
.notes p{padding:0 15px 11px;margin:0;font-size:15px}
.notes h2{padding:11px 15px 0;margin:0}
.aisle{padding:10px 15px;border-top:.5px solid var(--line)}
.aname{font-size:13px;color:var(--soft)}
.list ul{margin:2px 0 0;padding-left:18px}
.list li{font-size:14.5px}
.cand{color:var(--soft);font-size:13.5px}
.left-out,.sent{color:var(--soft);font-size:13.5px;padding:10px 15px;margin:0;border-top:.5px solid var(--line)}
.foot{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;margin-top:20px;padding-top:12px;border-top:.5px solid var(--line);color:var(--soft);font-size:13px}
a{color:var(--green)}
</style>
"#;
