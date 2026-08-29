// How a scenario writes a recipe or a dinner.
//
// These shapes are asserted character for character by features/corpus.feature,
// which is the schema definition. When the two disagree, corpus.feature is
// right.

export type Ingredient = { quantity: string; unit: string; item: string };

export type MealDraft = {
  /** "Dinner", "Breakfast", "Lunch" — whatever this household calls the meal. */
  name: string;
  /** How many people the meal feeds. Absent: it feeds what its recipes feed. */
  servings?: number;
  recipes: string[];
  note?: string;
};

export function slug(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
}

export function recipePath(name: string): string {
  return `recipes/${slug(name)}.md`;
}

export function dayPath(date: string): string {
  return `meals/${date}.md`;
}

export function ingredientLine(ingredient: Ingredient): string {
  const unit = ingredient.unit.trim();
  return `- ${ingredient.quantity.trim()}${unit ? ` ${unit}` : ''} ${ingredient.item.trim()}`;
}

export function recipeDocument(options: {
  name: string;
  servings: number;
  tags?: string[];
  ingredients?: Ingredient[];
}): string {
  const tags = options.tags?.length ? `[${options.tags.join(', ')}]` : '[]';
  const ingredients = (options.ingredients ?? []).map(ingredientLine);
  return [
    '---',
    `name: ${options.name}`,
    `servings: ${options.servings}`,
    `tags: ${tags}`,
    '---',
    '',
    `# ${options.name}`,
    '',
    '## Ingredients',
    '',
    ...(ingredients.length ? [...ingredients, ''] : []),
    '## Instructions',
    '',
  ].join('\n');
}

/**
 * One day, documented in one file.
 *
 * A day holds any number of meals, each its own `## <name>` section. A meal
 * carries an optional `servings:` line and links to its recipes directly
 * beneath it. Prose around the links is notes and is left alone.
 */
export function dayDocument(options: {
  date: string;
  meals?: MealDraft[];
  note?: string;
}): string {
  const parts = [
    '---',
    `date: ${options.date}`,
    '---',
    '',
    `# Meals for ${longDate(options.date)}`,
  ];

  for (const meal of options.meals ?? []) {
    parts.push('', `## ${meal.name}`, '');
    if (meal.servings !== undefined) {
      parts.push(`servings: ${meal.servings}`, '');
    }
    for (const name of meal.recipes) {
      parts.push(`- [${name}](../${recipePath(name)})`);
    }
    if (meal.recipes.length > 0 || meal.servings !== undefined) {
      parts.push('');
    }
    if (meal.note) {
      parts.push(meal.note, '');
    }
  }

  if (options.note) {
    parts.push('', options.note, '');
  }

  return parts.join('\n');
}

/**
 * A single-meal day, the common case. The meal is named "Dinner" so the
 * step wording "plan dinner" still writes what it says.
 */
export function dinnerDocument(options: {
  date: string;
  servings: number;
  recipes: string[];
  note?: string;
}): string {
  return dayDocument({
    date: options.date,
    meals: [
      { name: 'Dinner', servings: options.servings, recipes: options.recipes, note: options.note },
    ],
  });
}

/** "2026-08-25" -> "Tuesday, August 25, 2026". UTC, so it is deterministic. */
export function longDate(isoDate: string): string {
  const date = new Date(`${isoDate}T00:00:00Z`);
  const weekday = date.toLocaleDateString('en-US', { weekday: 'long', timeZone: 'UTC' });
  const month = date.toLocaleDateString('en-US', { month: 'long', timeZone: 'UTC' });
  return `${weekday}, ${month} ${date.getUTCDate()}, ${date.getUTCFullYear()}`;
}

/** Front matter as plain key/value text. The scenarios only need scalars. */
export function frontMatter(document: string): Record<string, string> {
  const match = /^---\n([\s\S]*?)\n---/.exec(document);
  if (!match) return {};
  const fields: Record<string, string> = {};
  for (const line of match[1].split('\n')) {
    const pair = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
    if (pair) fields[pair[1]] = pair[2].trim();
  }
  return fields;
}

/**
 * The `servings:` line inside a `## <meal>` section, if there is exactly one.
 *
 * A single-meal day is the case the "serves N" step asserts; a day with
 * several meals is read meal by meal instead.
 */
export function mealServings(document: string): number | null {
  const found: string[] = [];
  let insideMeal = false;
  for (const raw of document.split('\n')) {
    const line = raw.trim();
    if (/^##\s+/.test(line)) {
      insideMeal = true;
      continue;
    }
    if (/^#\s+/.test(line)) {
      insideMeal = false;
      continue;
    }
    const servings = /^servings:\s*(\d+(?:\.\d+)?)$/.exec(line);
    if (insideMeal && servings) found.push(servings[1]);
  }
  if (found.length !== 1) return null;
  const value = Number(found[0]);
  return Number.isFinite(value) ? value : null;
}

/**
 * The recipe links of a day document, as markdown link targets.
 *
 * Links sit directly under their meal heading now, so this is the whole of
 * "which recipes are planned that day".
 */
export function linkedRecipes(document: string): Array<{ name: string; target: string }> {
  return [...document.matchAll(/^-\s*\[([^\]]+)\]\(([^)]+)\)\s*$/gm)].map((match) => ({
    name: match[1],
    target: match[2],
  }));
}

/**
 * The ingredient lines of a recipe.
 *
 * Walked line by line rather than matched with one regular expression, because
 * the obvious expression needs an end-of-input anchor and JavaScript has no
 * \\Z. Written as a regex it silently matched nothing when `## Ingredients`
 * was the last section in the file.
 */
export function ingredientsOf(document: string): string[] {
  const found: string[] = [];
  let inside = false;
  for (const raw of document.split('\n')) {
    const line = raw.trim();
    const heading = /^#{1,6}\s+(.*)$/.exec(line);
    if (heading) {
      inside = heading[1].trim() === 'Ingredients';
      continue;
    }
    if (inside && line.startsWith('- ')) found.push(line);
  }
  return found;
}
