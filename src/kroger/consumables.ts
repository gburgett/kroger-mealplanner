// Bumping a pantry consumable's status when kroger_send_to_cart actually buys
// it. See ADR 0015.
//
// pantry/consumables.md is not the corpus grammar the CLI owns — ADR 0014 put
// it in the same "no validator, tolerant reader" class as the "## Sent" log in
// kroger/list.ts, and this is the same kind of reader: it writes a record of
// what happened, and a line it does not recognise is somebody's prose, left
// alone rather than guessed at.

const CONSUMABLE_LINE = /^-\s+(.+?):\s*(?:stocked|needs recheck)\b\s*(?:\(last bought:\s*\d{4}-\d{2}-\d{2}\))?\s*$/i;

function words(text: string): string[] {
  return text.toLowerCase().split(/[^a-z0-9]+/).filter((word) => word.length > 0);
}

/**
 * Whole-word match, the same rule `mealplan shopping-list` uses to match
 * staples and consumables against an ingredient — see `matches_any` in
 * cli/src/shopping_list.rs. "cheddar" matches "shredded cheddar" but not
 * "cheddar-flavored crackers".
 */
function namesTheItem(consumableItem: string, ingredientText: string): boolean {
  const needle = words(consumableItem);
  const haystack = words(ingredientText);
  if (needle.length === 0) return false;
  for (let start = 0; start + needle.length <= haystack.length; start += 1) {
    if (needle.every((word, offset) => haystack[start + offset] === word)) return true;
  }
  return false;
}

/**
 * Mark every tracked consumable that one of `boughtLines` names as stocked,
 * with today's date. `boughtLines` are the shopping-list item lines that were
 * just sent to the cart — the same text `mealplan shopping-list` rendered,
 * quantity and all, which is fine because the match is whole-word.
 *
 * A consumable with no matching line is untouched, and an item with no
 * consumable line is never given one: sending a product to Kroger is a
 * household decision to buy it, not a decision to start watching it. See the
 * "nothing is chosen for the household" rule this whole product follows.
 */
export function markConsumablesBought(text: string, boughtLines: string[], at: Date): string {
  const date = at.toISOString().slice(0, 10);
  return text
    .split('\n')
    .map((line) => {
      const match = CONSUMABLE_LINE.exec(line);
      if (!match) return line;
      const item = match[1].trim();
      const bought = boughtLines.some((ingredientText) => namesTheItem(item, ingredientText));
      if (!bought) return line;
      return `- ${item}: stocked (last bought: ${date})`;
    })
    .join('\n');
}
