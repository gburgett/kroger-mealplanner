//! What the pantry leaves off a meal plan's shopping list.
//!
//! `pantry/staples.md` names what is never bought; `pantry/consumables.md` names
//! what is kept but runs out, each "stocked" or "needs recheck". A plan's save
//! asks these three questions of every ingredient (ADR 0014, ADR 0016).

use crate::corpus::{Consumable, ConsumableStatus};

/// Whether the household always has this in.
pub fn is_staple(staples: &[String], item: &str) -> bool {
    matches_any(staples.iter(), item)
}

/// Whether the household still has plenty of this, per pantry/consumables.md.
///
/// A consumable with no matching line, or one marked "needs recheck" rather
/// than "stocked", is not left out — it is bought like any other ingredient.
pub fn is_stocked(consumables: &[Consumable], item: &str) -> bool {
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
pub fn needs_recheck(consumables: &[Consumable], item: &str) -> bool {
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
