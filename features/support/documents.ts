// How a scenario writes a recipe or a dinner.
//
// These shapes are asserted character for character by features/corpus.feature,
// which is the schema definition. When the two disagree, corpus.feature is
// right.

export type Ingredient = { quantity: string; unit: string; item: string };

export function slug(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
}

export function recipePath(name: string): string {
  return `recipes/${slug(name)}.md`;
}

export function dinnerPath(date: string): string {
  return `dinners/${date}.md`;
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

export function dinnerDocument(options: {
  date: string;
  servings: number;
  recipes: string[];
  note?: string;
}): string {
  const links = options.recipes.map((name) => `- [${name}](../${recipePath(name)})`);
  return [
    '---',
    `date: ${options.date}`,
    `servings: ${options.servings}`,
    '---',
    '',
    `# Dinner for ${longDate(options.date)}`,
    '',
    '## Recipes',
    '',
    ...(links.length ? [...links, ''] : []),
    '## Notes',
    ...(options.note ? ['', options.note] : []),
    '',
  ].join('\n');
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

/** The recipes a dinner links to, as markdown link targets. */
export function linkedRecipes(document: string): Array<{ name: string; target: string }> {
  return [...document.matchAll(/^-\s*\[([^\]]+)\]\(([^)]+)\)\s*$/gm)].map((match) => ({
    name: match[1],
    target: match[2],
  }));
}

export function ingredientsOf(document: string): string[] {
  const section = /^##\s+Ingredients\s*$([\s\S]*?)(?=^##\s|\Z)/m.exec(document);
  if (!section) return [];
  return section[1]
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('- '));
}
