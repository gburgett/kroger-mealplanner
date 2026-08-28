// The five tools. Three are the sandbox; two are the network the sandbox does
// not have, and they exist for that reason alone.
//
// THE TEST FOR A TOOL EXISTING IS NARROW, AND IT IS WRITTEN DOWN HERE BECAUSE
// THIS FILE IS WHERE IT WOULD BE BROKEN: a tool exists only when the sandbox
// cannot do the job BY CONSTRUCTION. The sandbox has no network by two
// independent controls — `--unshare-all` and seccomp denying `socket` — and
// neither is weakened, so a Kroger call cannot be made from inside it at all.
// That is the only such job in this product. "Is Kroger set up" is NOT one:
// `cat config/kroger.md` answers it, which is exactly why the store is written
// into the folder. See ADR 0006, ADR 0008 and ADR 0010.
//
// The descriptions are documentation the agent reads, so they are written for
// the agent: what the folder looks like, what the two commands are, and what
// is not there. `features/sandbox.feature` asserts that the bash description
// explains the folder layout, because an agent that has to guess the schema
// will invent one.

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { z } from 'zod';

import { resolveInsideFolder } from '../corpus/files.ts';
import type { Clock } from '../git/repository.ts';
import { commitIfChanged } from '../git/commit.ts';
import type { KrogerApi } from '../kroger/api.ts';
import { NotConfiguredError, NotLinkedError } from '../kroger/api.ts';
import { krogerHowTo } from '../kroger/help.ts';
import { readKrogerConfig } from '../kroger/config.ts';
import {
  appendSent,
  attachCandidates,
  moveToNotFound,
  parseList,
  unmatched,
  upcsIn,
  type Candidate,
} from '../kroger/list.ts';
import type { Session } from '../sandbox/session.ts';

export const BASH_DESCRIPTION = `Run a shell command in the meal-plan folder.

This is the whole interface. Explore and edit the meal plan the way you would
explore a repository: ls, grep, find, cat, sed, and writing files.

The folder is mounted at /workspace and every command starts there:

    README.md    the map — read it first
    recipes/     one document per recipe, filename is the name slugged
                 (recipes/chicken-tacos.md)
    dinners/     one document per night, filename is the ISO date
                 (dinners/2026-08-25.md)
    pantry/      staples.md: what the household always has in
    preferences/ household.md: how this household chooses — brands, what it
                 will not eat, cheap against good. Prose, with no schema.
                 Read it before you choose anything on their behalf.

An ingredient is one markdown list item, "- <quantity> [unit] <item>". No unit
means a count: "- 2 eggs". A dinner links to its recipes with ordinary markdown
links, so "grep -rl chicken-tacos.md dinners/" answers "when did we last make
this".

The folder is a git repository and every command that changes a file is
committed for you, with the message you provide. git log, git diff and
git restore all work, so nothing is lost by overwriting it.

Two commands are not exploration and should not be done from memory:

    mealplan validate [path]
        Check the folder, or one file, against the document format. Reports
        every problem, naming the file and the line.

    mealplan shopping-list --from YYYY-MM-DD --to YYYY-MM-DD
                           [--include-staples] [--out PATH] [--json]
        One shopping list for a range of nights, with the units added up and
        the pantry staples left out. Derived from the folder every time.
        --out writes it into shopping-lists/, which is what the Kroger tools
        then work on.

Two more folders:

    config/          kroger.md: which Kroger store the shopping is matched
                     against. "cat config/kroger.md" answers "is Kroger set up".
    shopping-lists/  one document per range of nights, written by
                     "mealplan shopping-list --out".

There is no network, and no interpreter: no python, node, perl or compiler.
Everything outside the folder is unreachable.`;

export const READ_FILE_DESCRIPTION = `Read a file from the meal-plan folder.

The path is relative to the folder root, for example "recipes/chicken-tacos.md".
Equivalent to "cat" through the bash tool; this is the convenient form.`;

export const WRITE_FILE_DESCRIPTION = `Create or overwrite a file in the meal-plan folder.

The path is relative to the folder root, for example "recipes/chicken-tacos.md".
The whole file is replaced, and the change is committed with the message you
provide, so an overwrite can always be walked back with git restore.

Missing directories on the way to the file are created.`;

const BASH_COMMAND_REQUIRED = 'the "bash" tool needs a "command": the shell command to run.';
const BASH_MESSAGE_REQUIRED =
  'the "bash" tool needs a "message": a commit message describing what this command ' +
  'changes. Every command that changes a file is committed with it.';

export const bashInputSchema = {
  command: z
    .string({ error: BASH_COMMAND_REQUIRED })
    .min(1, BASH_COMMAND_REQUIRED)
    .describe('The shell command to run, as bash would read it.'),
  message: z
    .string({ error: BASH_MESSAGE_REQUIRED })
    .trim()
    .min(1, BASH_MESSAGE_REQUIRED)
    .describe(
      'A commit message describing what this change does. Required — ' +
        'every command that changes a file is committed with this message.',
    ),
};

export const bashOutputSchema = {
  stdout: z.string().describe('What the command printed.'),
  stderr: z.string().describe('What the command printed to its error stream.'),
  exitCode: z.number().int().describe('Zero when the command succeeded.'),
  timedOut: z.boolean().describe('True when the command ran too long and was stopped.'),
  truncated: z.boolean().describe('True when output was dropped. The notice says how much.'),
};

const READ_FILE_PATH_REQUIRED = 'the "read_file" tool needs a "path": relative to the meal-plan folder root.';

export const readFileInputSchema = {
  path: z
    .string({ error: READ_FILE_PATH_REQUIRED })
    .min(1, READ_FILE_PATH_REQUIRED)
    .describe('Path relative to the meal-plan folder root.'),
};

export const readFileOutputSchema = {
  content: z.string().describe('The whole file.'),
};

const WRITE_FILE_PATH_REQUIRED = 'the "write_file" tool needs a "path": relative to the meal-plan folder root.';
const WRITE_FILE_CONTENT_REQUIRED =
  'the "write_file" tool needs "content": the whole new contents of the file. ' +
  'Leave it empty ("") to write an empty file on purpose.';
const WRITE_FILE_MESSAGE_REQUIRED =
  'the "write_file" tool needs a "message": a commit message describing what this ' +
  'change does. The change is committed with it.';

export const writeFileInputSchema = {
  path: z
    .string({ error: WRITE_FILE_PATH_REQUIRED })
    .min(1, WRITE_FILE_PATH_REQUIRED)
    .describe('Path relative to the meal-plan folder root.'),
  content: z
    .string({ error: WRITE_FILE_CONTENT_REQUIRED })
    .describe('The whole new contents of the file.'),
  message: z
    .string({ error: WRITE_FILE_MESSAGE_REQUIRED })
    .trim()
    .min(1, WRITE_FILE_MESSAGE_REQUIRED)
    .describe(
      'A commit message describing what this change does. Required — ' +
        'the change is committed with this message.',
    ),
};

export const writeFileOutputSchema = {
  path: z.string().describe('The path that was written.'),
  bytes: z.number().int().describe('How many bytes were written.'),
};

export type BashResult = {
  stdout: string;
  stderr: string;
  exitCode: number;
  timedOut: boolean;
  truncated: boolean;
};

export async function runBash(session: Session, command: string): Promise<BashResult> {
  const result = await session.run(command);
  return {
    stdout: result.stdout,
    stderr: result.stderr,
    exitCode: result.exitCode,
    timedOut: result.timedOut,
    truncated: result.truncated,
  };
}

export async function readCorpusFile(folder: string, requested: string): Promise<string> {
  const resolved = await resolveInsideFolder(folder, requested);
  try {
    return await readFile(resolved, 'utf8');
  } catch (error) {
    throw new Error(`could not read "${requested}": ${messageOf(error)}`);
  }
}

export async function writeCorpusFile(
  folder: string,
  requested: string,
  content: string,
): Promise<number> {
  const resolved = await resolveInsideFolder(folder, requested);
  await mkdir(path.dirname(resolved), { recursive: true });
  try {
    await writeFile(resolved, content, 'utf8');
  } catch (error) {
    throw new Error(`could not write "${requested}": ${messageOf(error)}`);
  }
  return Buffer.byteLength(content, 'utf8');
}

/** stdout and stderr, rendered for a reader rather than for a parser. */
export function renderBashResult(result: BashResult): string {
  const parts: string[] = [];
  if (result.stdout !== '') parts.push(result.stdout.replace(/\n$/, ''));
  if (result.stderr !== '') parts.push(result.stderr.replace(/\n$/, ''));
  if (result.exitCode !== 0) parts.push(`[exit status ${result.exitCode}]`);
  return parts.join('\n') || '[no output]';
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// ---------------------------------------------------------------------------
// The two tools that are the network.
//
// Both work on ONE document in shopping-lists/, and both resolve their path
// with resolveInsideFolder, so "cannot reach outside the folder" has exactly
// the shape read_file already has. Both write through session.enqueue() and
// commit, the write_file pattern, so the write and the commit stay atomic
// against a racing bash command.
// ---------------------------------------------------------------------------

export function findProductsDescription(baseUrl?: string): string {
  return `${FIND_PRODUCTS_DESCRIPTION}

CHANGING WHICH SHOP THE PRICES COME FROM

${krogerHowTo(baseUrl)}`;
}

export function sendToCartDescription(baseUrl?: string): string {
  return `${SEND_TO_CART_DESCRIPTION}

CONNECTING AN ACCOUNT, OR CHANGING WHICH SHOP

${krogerHowTo(baseUrl)}`;
}

export const FIND_PRODUCTS_DESCRIPTION = `Find Kroger products for the lines on a shopping list.

Give it a list written by "mealplan shopping-list --from ... --to ... --out
shopping-lists/<from>--<to>.md". It reads the range and the store out of the
document's front matter, searches Kroger once for each line, and writes the
products it found underneath that line, like this:

    - 8 oz shredded cheddar — 2026-08-25
      - 1 \`0001111050158\` Kroger Sharp Cheddar Shredded Cheese — 8 oz — $2.00
      - 1 \`0001111050170\` Kroger Mild Cheddar Shredded Cheese — 8 oz — $2.00

IT CHOOSES NOTHING. Searching for "boneless chicken thighs" returns noise as
well as thighs, and picking for the household is not yours to do. Two or more
candidates on a line means nobody has chosen yet, and kroger_send_to_cart will
refuse that line rather than guess.

To choose, DELETE the candidate lines you do not want, with the bash or
write_file tool, until one is left. Showing the household the candidates and
letting them say which is the right move when it is a real judgement — a brand
they care about, a size that is nearly double the price.

READ preferences/household.md BEFORE YOU DELETE ANYTHING. That is where this
household has written down how it chooses: brands, what it will not eat, the
shop's own brand against the name brand, cheap against good. It is prose with
no schema, so read it rather than parse it, and expect it to be in whatever
shape they have given it.

Then say which preference decided which line, so a wrong one can be corrected.

WHEN IT DOES NOT DECIDE A LINE, ASK — do not pick. Two candidates at the same
price and the same size, differing only in something nobody has an opinion on
record about, is the case this matters for: salted against unsalted butter is
not a judgement you can make for somebody else. Put the choice to the household,
and then WRITE THEIR ANSWER INTO preferences/household.md so the same question
is not asked again next week. That file is theirs to shape — add a heading,
reword a line, restructure it however it reads best.

EVERY COUNT IS WRITTEN AS 1, AND THAT IS OFTEN WRONG. Set it yourself by
comparing what the line needs against the package size: a line that wants 24 oz
matched to an 8 oz bag is a count of 3, not 1.

Lines Kroger has nothing for are moved to a "## Not found at this store"
section, listed rather than guessed at, so nothing goes quietly missing.

Lines that already have candidates are left alone, so running this again never
undoes a choice. To search for something again, move its line back out of "##
Not found at this store" first.

It needs a chosen store, because Kroger returns no price at all without one.
"cat config/kroger.md" says which shop is set, and how to change it.`;

export const SEND_TO_CART_DESCRIPTION = `Add the chosen products on a shopping list to the household's Kroger cart.

With no "items", it sends every line that has exactly ONE candidate left. A line
with two or more stops the whole send and names the line, because a half-sent
cart cannot be walked back. A line with none is skipped and reported.

With "items", it sends only those, and it REFUSES ANY UPC THAT IS NOT WRITTEN IN
THAT FILE. So "add that cheese back, my husband deleted it" is an ordinary call:
pick the UPC off the line you can already see in the document.

TWO THINGS TO SAY OUT LOUD RATHER THAN GUESS AT:

  * This ADDS TO A CART. It does not place an order. No money moves until
    somebody opens the Kroger app and checks out. Say so.
  * KROGER'S CART CANNOT BE READ. There is no read, no update and no delete on
    the public API — adding is the whole of it. So you can never say what is in
    the cart, only what was sent. Never tell the household the cart "now
    contains" anything.

What was sent is appended to the document under "## Sent", as a record of what
was asked for. That is not a claim about what the cart holds either.

It needs a connected Kroger account. "cat config/kroger.md" says whether there
is one.`;

const FIND_PRODUCTS_PATH_REQUIRED =
  'the "kroger_find_products" tool needs a "path": the shopping list to search from, ' +
  'relative to the folder root.';
const FIND_PRODUCTS_MESSAGE_REQUIRED =
  'the "kroger_find_products" tool needs a "message": a commit message describing ' +
  'what this search is for. The candidates written to the list are committed with it.';

export const findProductsInputSchema = {
  path: z
    .string({ error: FIND_PRODUCTS_PATH_REQUIRED })
    .min(1, FIND_PRODUCTS_PATH_REQUIRED)
    .describe(
      'The shopping list, relative to the folder root, for example ' +
        '"shopping-lists/2026-08-25--2026-08-31.md".',
    ),
  message: z
    .string({ error: FIND_PRODUCTS_MESSAGE_REQUIRED })
    .trim()
    .min(1, FIND_PRODUCTS_MESSAGE_REQUIRED)
    .describe(
      'A commit message describing what this search is for. Required — ' +
        'candidates written to the list are committed with this message.',
    ),
};

export const findProductsOutputSchema = {
  path: z.string().describe('The list that was written.'),
  matched: z.number().int().describe('How many lines got candidates.'),
  notFound: z.array(z.string()).describe('The items Kroger had nothing for.'),
  searched: z.number().int().describe('How many searches were made. One per line, never per product.'),
};

const SEND_TO_CART_PATH_REQUIRED =
  'the "kroger_send_to_cart" tool needs a "path": the shopping list to send from, ' +
  'relative to the folder root.';
const SEND_TO_CART_MESSAGE_REQUIRED =
  'the "kroger_send_to_cart" tool needs a "message": a commit message describing ' +
  'what is being sent. The sent status written to the list is committed with it.';
const SEND_TO_CART_UPC_REQUIRED =
  'an entry in "items" for "kroger_send_to_cart" needs a "upc": a UPC already ' +
  'written on the list.';

export const sendToCartInputSchema = {
  path: z
    .string({ error: SEND_TO_CART_PATH_REQUIRED })
    .min(1, SEND_TO_CART_PATH_REQUIRED)
    .describe('The shopping list, relative to the folder root.'),
  message: z
    .string({ error: SEND_TO_CART_MESSAGE_REQUIRED })
    .trim()
    .min(1, SEND_TO_CART_MESSAGE_REQUIRED)
    .describe(
      'A commit message describing what is being sent. Required — ' +
        'the sent status written to the list is committed with this message.',
    ),
  items: z
    .array(
      z.object({
        upc: z
          .string({ error: SEND_TO_CART_UPC_REQUIRED })
          .min(1, SEND_TO_CART_UPC_REQUIRED)
          .describe('A 13-character UPC already written in that list.'),
        quantity: z
          .number()
          .int()
          .min(1, 'an entry in "items" for "kroger_send_to_cart" needs "quantity" to be at least 1.')
          .describe('How many packages. Defaults to the count on the line.'),
      }),
    )
    .optional()
    .describe('Only these products. Leave it out to send every chosen line.'),
};

export const sendToCartOutputSchema = {
  path: z.string().describe('The list that was sent from.'),
  sent: z
    .array(z.object({ upc: z.string(), quantity: z.number().int(), description: z.string() }))
    .describe('What was ASKED FOR. The cart cannot be read, so this is not what it holds.'),
  skipped: z.array(z.string()).describe('Lines with nothing chosen on them.'),
};

export type FindProductsResult = {
  path: string;
  matched: number;
  notFound: string[];
  searched: number;
};

export type SendToCartResult = {
  path: string;
  sent: Array<{ upc: string; quantity: number; description: string }>;
  skipped: string[];
};

/**
 * How many products to write under one line.
 *
 * Enough to choose from, few enough to read. Kroger's own ceiling is 50 and the
 * daily budget is 10,000 searches, so this is about the document rather than
 * about the API: twelve candidates under every line is a file nobody reads.
 */
const CANDIDATES_PER_LINE = 5;

export async function findProducts(options: {
  session: Session;
  folder: string;
  now: Clock;
  kroger: KrogerApi | null;
  requested: string;
  message: string;
  /** This server's address, so a refusal can say where a person has to go. */
  baseUrl?: string;
}): Promise<FindProductsResult> {
  const { session, folder, now, kroger, requested, message, baseUrl } = options;
  // Searching uses the SERVER'S application token, not the household's, so a
  // link is not needed for it — only a store, because Kroger returns no price
  // without one. Sending is what needs the household's credential.
  if (!kroger) throw new NotConfiguredError();

  const resolved = await resolveInsideFolder(folder, requested);
  const config = await readKrogerConfig(folder);
  if (!config.store) {
    throw new Error(
      'no Kroger shop is chosen, and Kroger returns no prices at all without one.\n\n' +
        krogerHowTo(baseUrl ?? kroger.publicUrl),
    );
  }

  const before = await readFile(resolved, 'utf8').catch((error: unknown) => {
    throw new Error(`could not read "${requested}": ${messageOf(error)}`);
  });
  const list = parseList(requested, before);
  const waiting = unmatched(list);

  // The structure comes from the CLI, which is the same parser that wrote the
  // document. Nothing here reads the ingredient grammar. See ADR 0010.
  const structure = await shoppingListStructure(session, list.front, requested);
  const items = new Map(structure.map((item) => [item.line, item]));

  const found = new Map<string, Candidate[]>();
  const notFound: string[] = [];
  let searched = 0;

  for (const item of waiting) {
    const known = items.get(item.text);
    if (!known) continue;
    // ONE SEARCH PER ITEM, never one per candidate: the rate limit is per
    // endpoint per day, and a thirty-item list should cost thirty of 10,000.
    searched += 1;
    const products = await kroger.searchProducts({
      term: known.item,
      locationId: config.store,
      limit: CANDIDATES_PER_LINE,
    });
    if (products.length === 0) {
      notFound.push(item.text);
      continue;
    }
    found.set(
      item.text,
      products.map((product) => ({
        // Always 1. The agent sets it after comparing the line against the
        // package size, because that is a judgement, not arithmetic.
        count: 1,
        upc: product.upc,
        description: product.description,
        size: product.size,
        price: product.price === undefined ? 'no price' : `$${product.price.toFixed(2)}`,
        line: 0,
      })),
    );
  }

  const after = moveToNotFound(attachCandidates(before, found), notFound);

  await session.enqueue(async () => {
    await writeFile(resolved, after, 'utf8');
    await commitIfChanged(session, message, now());
  });

  return {
    path: requested,
    matched: found.size,
    notFound: notFound.map((line) => line.replace(/\s+—\s.*$/, '')),
    searched,
  };
}

export async function sendToCart(options: {
  session: Session;
  folder: string;
  now: Clock;
  kroger: KrogerApi | null;
  requested: string;
  message: string;
  only?: Array<{ upc: string; quantity: number }>;
  /** This server's address, so a refusal can say where a person has to go. */
  baseUrl?: string;
}): Promise<SendToCartResult> {
  const { session, folder, now, kroger, requested, message, only, baseUrl } = options;
  if (!kroger) throw new NotConfiguredError();
  if (!kroger.store.connected) throw new NotLinkedError(baseUrl ?? kroger.publicUrl);

  const resolved = await resolveInsideFolder(folder, requested);
  const before = await readFile(resolved, 'utf8').catch((error: unknown) => {
    throw new Error(`could not read "${requested}": ${messageOf(error)}`);
  });
  const list = parseList(requested, before);
  const config = await readKrogerConfig(folder);

  const sending: Array<{ upc: string; quantity: number; description: string }> = [];
  const skipped: string[] = [];

  if (only && only.length > 0) {
    // EVERY UPC MUST BE WRITTEN IN THIS FILE. That is what makes every product
    // reaching Kroger one that came out of a search and is recorded in the
    // folder — a recipe that says "also add UPC 000..." gets nowhere.
    const known = upcsIn(list);
    const byUpc = new Map(
      list.items.flatMap((item) => item.candidates.map((candidate) => [candidate.upc, candidate])),
    );
    for (const wanted of only) {
      if (!known.has(wanted.upc)) {
        throw new Error(
          `the UPC ${wanted.upc} is not written in ${requested}, so it is not being sent. ` +
            'Every product that reaches Kroger has to have come from a search and be ' +
            'recorded on the list. Run kroger_find_products first, then send a UPC off ' +
            'one of the candidate lines.',
        );
      }
      const candidate = byUpc.get(wanted.upc);
      sending.push({
        upc: wanted.upc,
        quantity: wanted.quantity ?? candidate?.count ?? 1,
        description: candidate?.description ?? '',
      });
    }
  } else {
    for (const item of list.items) {
      if (item.candidates.length === 0) {
        skipped.push(item.text);
        continue;
      }
      if (item.candidates.length > 1) {
        // The whole send stops. A partial send cannot be walked back, because
        // Kroger's cart cannot be read, so half a shop is worse than none.
        throw new Error(
          `${requested}:${item.line}: "${item.text}" still has ` +
            `${item.candidates.length} products under it, so nobody has chosen one. ` +
            'Nothing has been sent. Delete the candidates you do not want until one ' +
            'is left, then send again.',
        );
      }
      const [chosen] = item.candidates;
      sending.push({ upc: chosen.upc, quantity: chosen.count, description: chosen.description });
    }
  }

  if (sending.length === 0) {
    return { path: requested, sent: [], skipped };
  }

  // KROGER ADDS TO THE QUANTITY ON A REPEATED ADD. It does not replace —
  // measured 2026-08-26, ADR 0012 — so sending this list again buys the week
  // twice, and the housewife finds out at the store.
  //
  // Only a whole-list send is stopped. `only` is the household naming one
  // product on purpose, which is how a thing deleted in the Kroger app gets put
  // back, and it is not a repeat.
  if (!only || only.length === 0) {
    const alreadySent = new Map(list.sent.map((entry) => [entry.upc, entry]));
    const repeats = sending.filter((item) => alreadySent.has(item.upc));
    if (repeats.length > 0) {
      const last = list.sent[list.sent.length - 1];
      throw new Error(
        `${requested} has already been sent to the cart, the last time at ${last.at}. ` +
          'Kroger ADDS to the quantity rather than replacing it, so sending it again ' +
          `would buy ${repeats.length === 1 ? 'this' : 'these'} twice:\n` +
          repeats
            .map((item) => `  ${item.quantity} \`${item.upc}\` ${item.description}`.trimEnd())
            .join('\n') +
          '\n\nNothing has been sent. Read the "## Sent" section of the file — it says ' +
          'what went, and when. To put one product back that the household deleted in ' +
          'the Kroger app, send that UPC on its own with "items". To shop another week, ' +
          'write a new list with "mealplan shopping-list --from DATE --to DATE --out <path>".',
      );
    }
  }

  await kroger.addToCart(
    sending.map((item) => ({ upc: item.upc, quantity: item.quantity })),
    config.modality,
  );

  const after = appendSent(before, sending, now());
  await session.enqueue(async () => {
    await writeFile(resolved, after, 'utf8');
    await commitIfChanged(session, message, now());
  });

  return { path: requested, sent: sending, skipped };
}

/**
 * The list, as structure, from the command that wrote it.
 *
 * This is the seam ADR 0010 defends: the server gets quantities, units and item
 * names from `mealplan shopping-list --json`, and never by parsing the markdown
 * back. The ingredient grammar has exactly one implementation, in the CLI.
 */
async function shoppingListStructure(
  session: Session,
  front: Record<string, string>,
  requested: string,
): Promise<Array<{ item: string; line: string; quantity: string; unit: string | null }>> {
  const from = front.from ?? '';
  const to = front.to ?? '';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to)) {
    throw new Error(
      `${requested}: the front matter needs "from:" and "to:" as dates, written as ` +
        'YYYY-MM-DD. Write the list with "mealplan shopping-list --from DATE --to DATE ' +
        `--out ${requested}".`,
    );
  }

  const command =
    `mealplan shopping-list --from ${from} --to ${to} --json > /tmp/mealplan-list.json 2>&1; ` +
    'status=$?; cat /tmp/mealplan-list.json; exit $status';
  const result = await session.run(command, { commit: false });
  if (result.exitCode !== 0) {
    throw new Error(
      `mealplan shopping-list could not derive the list for ${from} to ${to}:\n` +
        `${result.stdout}${result.stderr}`,
    );
  }

  let parsed: {
    sections?: Array<{ items?: Array<{ item?: string; line?: string; quantity?: string; unit?: string | null }> }>;
  };
  try {
    parsed = JSON.parse(result.stdout) as typeof parsed;
  } catch (error) {
    throw new Error(
      `mealplan shopping-list --json did not print JSON: ${messageOf(error)}\n${result.stdout}`,
    );
  }

  return (parsed.sections ?? []).flatMap((section) =>
    (section.items ?? []).map((item) => ({
      item: item.item ?? '',
      line: item.line ?? '',
      quantity: item.quantity ?? '',
      unit: item.unit ?? null,
    })),
  );
}
