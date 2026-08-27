// The candidate grammar, defined here and nowhere else.
//
// THIS IS THE ONE PLACE THE SERVER READS PART OF A DOCUMENT, and ADR 0010 says
// so out loud rather than letting it happen quietly. The boundary that keeps it
// honest:
//
//   * The ingredient grammar stays in the CLI. Nothing here parses
//     `- <quantity> [unit] <item>`; the structure comes from
//     `mealplan shopping-list --json`, which is the same parser that wrote the
//     document.
//   * What is read here is a grammar the CLI never emits and never parses —
//     the indented candidate lines the SERVER wrote.
//   * A malformed annotation fails loudly, naming the file and the line, the
//     same discipline the CLI's own errors follow.
//
// The shape is fixed so that a bare `grep` answers "which products are in
// play":
//
//     - <count> `<upc>` <description> — <size> — <price>
//
//     grep -o '`[0-9]\{13\}`' shopping-lists/2026-08-25--2026-08-31.md
//
// BLOCKS ARE ANCHORED BY THE EXACT TEXT OF THE ITEM LINE, never by a line
// number. The agent edits this file freehand between the two tool calls — that
// is the whole interface — so a block placed by line number would land on the
// wrong item the moment anything above it moved.

/** Headings whose list items are not shopping items. */
const NOT_FOUND_HEADING = 'Not found at this store';
const SENT_HEADING = 'Sent';
const LEFT_OUT_HEADING = 'Left out';
const PROSE_SECTIONS = new Set([LEFT_OUT_HEADING, SENT_HEADING]);

/** A 13-character zero-padded string, and it must stay a string. */
const UPC = /^[0-9]{13}$/;

const CANDIDATE = /^\s+-\s+(\S+)\s+`([^`]*)`\s*(.*)$/;

/**
 * A line under `## Sent`, as appendSent writes it:
 *
 *     - 2026-08-26T12:54:35Z — 2 `0001111050158` Kroger Sharp Cheddar
 *
 * Read back because Kroger ADDS to the quantity on a repeated add rather than
 * replacing it — measured 2026-08-26, ADR 0012 — so this log is what stops the
 * same list going twice and buying the week twice.
 */
const SENT_LINE = /^-\s+(\S+)\s+—\s+(\d+)\s+`([^`]*)`\s*(.*)$/;

export type Candidate = {
  /**
   * How many of this product to buy.
   *
   * Always WRITTEN as 1. The agent sets it by comparing what the line needs
   * against the package size — three 8 oz bags for 24 oz is a 3 — because that
   * is a judgement about the household's week, not an arithmetic fact.
   */
  count: number;
  upc: string;
  description: string;
  size: string;
  /** As written, so a re-read never re-formats somebody's number. */
  price: string;
  /** One-based, for error messages. */
  line: number;
};

export type ListItem = {
  /** The item line without its `- `. This is the anchor. */
  text: string;
  section: string;
  /** One-based, for error messages. */
  line: number;
  candidates: Candidate[];
};

/** One line of the `## Sent` log: a product this list already asked Kroger for. */
export type SentEntry = {
  /** ISO 8601, as written. */
  at: string;
  quantity: number;
  upc: string;
  description: string;
  /** One-based, for error messages. */
  line: number;
};

export type ShoppingList = {
  front: Record<string, string>;
  items: ListItem[];
  /**
   * What this list has already sent to the cart, oldest first.
   *
   * NOT A CLAIM ABOUT WHAT THE CART HOLDS — the household may have emptied it
   * in the Kroger app, and there is no read to check. It is a record of what
   * this file asked for, which is the only thing that can be known.
   */
  sent: SentEntry[];
};

/** A document that does not read as a shopping list, named well enough to fix. */
export class ListFormatError extends Error {
  constructor(file: string, line: number | null, message: string) {
    super(line === null ? `${file}: ${message}` : `${file}:${line}: ${message}`);
    this.name = 'ListFormatError';
  }
}

// --- reading ---------------------------------------------------------------

export function parseList(file: string, text: string): ShoppingList {
  const lines = text.split('\n');
  const front = frontMatter(lines);
  if (front === null) {
    throw new ListFormatError(
      file,
      1,
      'this is not a shopping list: it has no front matter. Write one with ' +
        '`mealplan shopping-list --from DATE --to DATE --out <path>`.',
    );
  }

  const items: ListItem[] = [];
  const sent: SentEntry[] = [];
  let section = '';
  let current: ListItem | null = null;

  for (let index = 0; index < lines.length; index += 1) {
    const raw = lines[index];
    const number = index + 1;

    const heading = /^#{1,6}\s+(.*)$/.exec(raw.trim());
    if (heading) {
      section = heading[1].trim();
      current = null;
      continue;
    }

    // A line of the sent log. Flush left like an item line, but under a heading
    // that is a record ABOUT the list rather than part of it.
    if (/^-\s+/.test(raw) && section === SENT_HEADING) {
      const logged = SENT_LINE.exec(raw);
      // Anything else under this heading is prose somebody wrote, and prose is
      // theirs to write. It is a log, not a schema.
      if (logged) {
        sent.push({
          at: logged[1],
          quantity: Number(logged[2]),
          upc: logged[3],
          description: logged[4].trim(),
          line: number,
        });
      }
      continue;
    }

    // An item line: flush left, under a section that holds items.
    if (/^-\s+/.test(raw) && !PROSE_SECTIONS.has(section)) {
      current = { text: raw.replace(/^-\s+/, '').trim(), section, line: number, candidates: [] };
      items.push(current);
      continue;
    }

    if (/^\s+-\s/.test(raw)) {
      if (!current) {
        throw new ListFormatError(
          file,
          number,
          `this candidate is not under any shopping line: ${raw.trim()}. A candidate is ` +
            'indented beneath the item it is for.',
        );
      }
      current.candidates.push(parseCandidate(file, number, raw));
      continue;
    }

    // Anything else — prose, a blank line — ends the block.
    if (raw.trim() === '') current = null;
  }

  return { front, items, sent };
}

function parseCandidate(file: string, number: number, raw: string): Candidate {
  const complaint = (why: string): never => {
    throw new ListFormatError(
      file,
      number,
      `${why} A candidate is written as ` +
        '"  - <count> `<upc>` <description> — <size> — <price>", for example ' +
        '"  - 1 `0001111050158` Kroger Sharp Cheddar Shredded Cheese — 8 oz — $2.00". ' +
        'To choose a product, delete the other candidates; to buy more than one ' +
        'package, change the count.',
    );
  };

  const found = CANDIDATE.exec(raw);
  if (!found) complaint(`cannot read this candidate: ${raw.trim()}.`);

  const [, rawCount, upc, rest] = found as RegExpExecArray;
  const count = Number(rawCount);
  if (!Number.isInteger(count) || count < 1) {
    complaint(`the count "${rawCount}" is not a whole number of one or more.`);
  }
  if (!UPC.test(upc)) {
    complaint(
      `"${upc}" is not a Kroger UPC. A UPC is 13 digits, zero-padded, and keeps its leading zeros.`,
    );
  }

  const parts = rest.split(' — ');
  return {
    count,
    upc,
    description: (parts[0] ?? '').trim(),
    size: (parts[1] ?? '').trim(),
    price: (parts[2] ?? '').trim(),
    line: number,
  };
}

/** The item lines that are still waiting to be matched against Kroger. */
export function unmatched(list: ShoppingList): ListItem[] {
  return list.items.filter(
    (item) => item.candidates.length === 0 && item.section !== NOT_FOUND_HEADING,
  );
}

/** Every UPC written anywhere in the document. The allow list for a cart send. */
export function upcsIn(list: ShoppingList): Set<string> {
  return new Set(list.items.flatMap((item) => item.candidates.map((candidate) => candidate.upc)));
}

// --- writing ---------------------------------------------------------------

/**
 * Write candidate blocks beneath the item lines they belong to.
 *
 * `found` is keyed by the item line's exact text. An anchor that is no longer
 * in the document is skipped rather than guessed at: the agent may have deleted
 * the line while the search was in flight, and inventing a place to put it
 * would be worse than doing nothing.
 */
export function attachCandidates(text: string, found: Map<string, Candidate[]>): string {
  const lines = text.split('\n');
  const out: string[] = [];

  for (const raw of lines) {
    out.push(raw);
    if (!/^-\s+/.test(raw)) continue;
    const anchor = raw.replace(/^-\s+/, '').trim();
    const candidates = found.get(anchor);
    if (!candidates || candidates.length === 0) continue;
    for (const candidate of candidates) out.push(renderCandidate(candidate));
  }

  return out.join('\n');
}

export function renderCandidate(candidate: Candidate): string {
  return (
    `  - ${candidate.count} \`${candidate.upc}\` ${clean(candidate.description)}` +
    ` — ${clean(candidate.size) || 'size unknown'} — ${clean(candidate.price) || 'no price'}`
  );
}

/**
 * Move the item lines Kroger had nothing for into their own section.
 *
 * Listed rather than guessed at. A line the meal planner quietly dropped is the
 * housewife finding out at the store, which is the failure this whole product
 * is written to avoid.
 */
export function moveToNotFound(text: string, anchors: string[]): string {
  if (anchors.length === 0) return text;
  const wanted = new Set(anchors);
  const lines = text.split('\n');
  const kept: string[] = [];
  const moved: string[] = [];

  for (const raw of lines) {
    if (/^-\s+/.test(raw) && wanted.has(raw.replace(/^-\s+/, '').trim())) {
      moved.push(raw);
      continue;
    }
    kept.push(raw);
  }
  if (moved.length === 0) return text;

  return insertSection(
    dropEmptySections(kept),
    NOT_FOUND_HEADING,
    [
      'Kroger returned nothing for these at this store. They are still on the list:',
      'search for them by hand, or write the product in yourself.',
      '',
      ...moved,
    ],
    // Before the two sections that are records ABOUT the list rather than part
    // of it. This one is still shopping.
    [`## ${LEFT_OUT_HEADING}`, `## ${SENT_HEADING}`],
  );
}

/**
 * Append a record of what was asked for.
 *
 * ITS OWN TEXT SAYS IT IS NOT A CLAIM ABOUT WHAT THE CART HOLDS, because the
 * public cart is add-only and cannot be read back. An agent that reads this
 * section a week later must not conclude that the cheese is still in there.
 */
export function appendSent(
  text: string,
  sent: Array<{ upc: string; quantity: number; description: string }>,
  at: Date,
): string {
  const stamp = at.toISOString().replace(/\.\d{3}Z$/, 'Z');
  return insertSection(
    text.split('\n'),
    SENT_HEADING,
    [
      'What was sent to the Kroger cart, and when. Kroger\'s cart is add-only and',
      'cannot be read back, so this says what was ASKED FOR — it is not a record of',
      'what the cart holds now.',
      '',
      ...sent.map(
        (item) => `- ${stamp} — ${item.quantity} \`${item.upc}\` ${clean(item.description)}`,
      ),
    ],
    // At the very end. It is a log, and a log belongs under everything it is
    // a log of.
    [],
  );
}

// --- the plumbing ----------------------------------------------------------

function frontMatter(lines: string[]): Record<string, string> | null {
  if (lines[0]?.trim() !== '---') return null;
  const end = lines.findIndex((line, index) => index > 0 && line.trim() === '---');
  if (end < 0) return null;

  const front: Record<string, string> = {};
  for (const line of lines.slice(1, end)) {
    const pair = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
    if (pair) front[pair[1]] = pair[2].trim();
  }
  return front;
}

/**
 * Add to a section, or start one.
 *
 * `before` names the headings this section must come above. An empty list puts
 * it at the very end. Called again for a heading that is already there, it adds
 * the new list items to the end of it and leaves the note alone.
 */
function insertSection(
  lines: string[],
  heading: string,
  body: string[],
  before: string[],
): string {
  const headingAt = lines.findIndex((line) => line.trim() === `## ${heading}`);
  if (headingAt >= 0) {
    // Already there: add the list items to the end of it, keeping the note.
    const nextAt = lines.findIndex((line, index) => index > headingAt && /^##\s/.test(line.trim()));
    const end = nextAt < 0 ? lines.length : nextAt;
    const items = body.filter((line) => line.startsWith('- '));
    const above = lines.slice(0, end);
    while (above.length > 0 && above[above.length - 1].trim() === '') above.pop();
    return [...above, ...items, '', ...lines.slice(end)].join('\n').replace(/\n+$/, '\n');
  }

  let insertAt = before.length === 0 ? -1 : lines.findIndex((line) => before.includes(line.trim()));
  if (insertAt < 0) insertAt = lines.length;

  const above = lines.slice(0, insertAt);
  while (above.length > 0 && above[above.length - 1].trim() === '') above.pop();
  const below = lines.slice(insertAt);
  return [...above, '', `## ${heading}`, '', ...body, '', ...below]
    .join('\n')
    .replace(/\n+$/, '\n');
}

/** A section heading with nothing left under it is noise. Take it out. */
function dropEmptySections(lines: string[]): string[] {
  const out: string[] = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (!/^##\s/.test(line.trim())) {
      out.push(line);
      continue;
    }
    let hasContent = false;
    for (let ahead = index + 1; ahead < lines.length; ahead += 1) {
      const next = lines[ahead];
      if (/^##\s/.test(next.trim())) break;
      if (next.trim() !== '') {
        hasContent = true;
        break;
      }
    }
    if (hasContent) {
      out.push(line);
      continue;
    }
    // Take the blank line above the dead heading, and skip the blank lines
    // below it, or the gap it leaves grows every time a section empties.
    while (out.length > 0 && out[out.length - 1].trim() === '') out.pop();
    while (index + 1 < lines.length && lines[index + 1].trim() === '') index += 1;
    if (out.length > 0) out.push('');
  }
  return out;
}

/**
 * Third-party text, made safe for one line of a markdown document.
 *
 * A product description comes from Kroger and goes into a file the agent reads
 * back. A newline in it would end the candidate; an em dash would split the
 * fields; a backtick would break the UPC out of its quoting. None of those are
 * likely and all of them are cheap to make impossible.
 */
function clean(text: string): string {
  return text
    .replace(/[`—\r\n]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}
