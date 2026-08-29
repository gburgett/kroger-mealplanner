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
import { markConsumablesBought } from '../kroger/consumables.ts';
import {
  appendCartLink,
  appendSent,
  attachCandidates,
  isKrogerUpc,
  isWalmartItemId,
  moveToNotFound,
  parseList,
  productIdsIn,
  unmatched,
  walmartItemId,
  type Candidate,
} from '../kroger/list.ts';
import type { Session } from '../sandbox/session.ts';
import type { WalmartApi } from '../walmart/api.ts';
import { MAX_LINK_ITEMS, NotConfiguredError as WalmartNotConfiguredError } from '../walmart/api.ts';
import { readWalmartConfig } from '../walmart/config.ts';
import { walmartHowTo } from '../walmart/help.ts';

export const BASH_DESCRIPTION = `Run a shell command in the meal-plan folder.

This is the whole interface. Explore and edit the meal plan the way you would
explore a repository: ls, grep, find, cat, sed, and writing files.

The folder is mounted at /workspace and every command starts there:

    README.md    the map — read it first
    recipes/     one document per recipe, filename is the name slugged
                 (recipes/chicken-tacos.md)
    dinners/     one document per night, filename is the ISO date
                 (dinners/2026-08-25.md)
    pantry/      staples.md: what the household never buys. consumables.md:
                 what it keeps some of but runs out — "stocked" leaves it off
                 the shopping list, "needs recheck" puts it back on
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
                           [--include-staples] [--include-consumables]
                           [--out PATH] [--json]
        One shopping list for a range of nights, with the units added up, the
        pantry staples left out, and any stocked consumable left out too. A
        consumable marked "needs recheck" is bought, but its line is marked
        "(check)" — ask the household whether they already have it before
        buying it, since kroger_send_to_cart refuses to send while any line
        is still marked that way. Derived from the folder every time. --out
        writes it into shopping-lists/, which is what the Kroger tools then
        work on.

Two more folders:

    config/          kroger.md: which Kroger store the shopping is matched
                     against. "cat config/kroger.md" answers "is Kroger set up".
                     walmart.md: which Walmart store cart links are built for.
                     No sign-in is needed for Walmart; walmart_find_stores
                     finds the stores and you write the file.
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

IT REFUSES THE WHOLE SEND IF ANY LINE ON THE LIST IS STILL MARKED "(check)".
That marker means pantry/consumables.md says the household might already have
the item, and nobody has said either way. Ask the household: delete the line
if they still have it, or remove "(check)" from the line if they need it —
either is an ordinary edit — then send again.

TWO THINGS TO SAY OUT LOUD RATHER THAN GUESS AT:

  * This ADDS TO A CART. It does not place an order. No money moves until
    somebody opens the Kroger app and checks out. Say so.
  * KROGER'S CART CANNOT BE READ. There is no read, no update and no delete on
    the public API — adding is the whole of it. So you can never say what is in
    the cart, only what was sent. Never tell the household the cart "now
    contains" anything.

What was sent is appended to the document under "## Sent", as a record of what
was asked for. That is not a claim about what the cart holds either.

Any item sent that matches a line in pantry/consumables.md is marked "stocked"
there, with today's date, so a pantry item bought this way needs no hand edit
afterward. An item with no line in that file is not given one — sending a
product to Kroger is a decision to buy it, not a decision to start tracking it.

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
  notFound: z.array(z.string()).describe('The items the shop had nothing for.'),
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
        productId: product.upc,
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

  // "(check)" is the literal suffix `mealplan shopping-list` appends to a line
  // sourced from a consumable pantry/consumables.md still calls "needs
  // recheck" — see ADR 0016. This reads that one fixed marker off the anchor
  // text, not the ingredient grammar itself, which stays the CLI's alone.
  // Sending while it is still there would be exactly the silent guess this
  // product refuses to make: nobody has said the household is actually out.
  const CHECK_MARK = ' (check)';
  const needsCheck = list.items.filter((item) => item.text.endsWith(CHECK_MARK));
  if (needsCheck.length > 0) {
    throw new Error(
      `${requested} still has ${needsCheck.length === 1 ? 'a line' : `${needsCheck.length} lines`} ` +
        'marked "(check)", so nothing has been sent:\n' +
        needsCheck.map((item) => `  ${item.text}`).join('\n') +
        '\n\npantry/consumables.md still says these need a recheck. Ask the household whether ' +
        'they already have them: delete the line if they do, or remove "(check)" from the ' +
        'line if they need it.',
    );
  }

  const config = await readKrogerConfig(folder);

  const sending: Array<{ upc: string; quantity: number; description: string }> = [];
  // The shopping-list line text each entry of `sending` came from, same order
  // and length. Kept separate from `sending` because it is only for matching
  // against pantry/consumables.md — see markConsumablesBought — and has no
  // business in the tool's result.
  const sendingLines: string[] = [];
  const skipped: string[] = [];

  if (only && only.length > 0) {
    // EVERY UPC MUST BE WRITTEN IN THIS FILE. That is what makes every product
    // reaching Kroger one that came out of a search and is recorded in the
    // folder — a recipe that says "also add UPC 000..." gets nowhere.
    const known = productIdsIn(list);
    const byUpc = new Map(
      list.items.flatMap((item) =>
        item.candidates.map((candidate) => [candidate.productId, { item, candidate }] as const),
      ),
    );
    for (const wanted of only) {
      if (!isKrogerUpc(wanted.upc)) {
        throw new Error(
          `"${wanted.upc}" is not a Kroger UPC, so it is not being sent. A Kroger UPC is ` +
            '13 digits, zero-padded. ' +
            (isWalmartItemId(wanted.upc)
              ? 'That one is a Walmart product — walmart_cart_link builds the link for those.'
              : 'If it came from a Walmart search, use walmart_cart_link instead.'),
        );
      }
      if (!known.has(wanted.upc)) {
        throw new Error(
          `the UPC ${wanted.upc} is not written in ${requested}, so it is not being sent. ` +
            'Every product that reaches Kroger has to have come from a search and be ' +
            'recorded on the list. Run kroger_find_products first, then send a UPC off ' +
            'one of the candidate lines.',
        );
      }
      const found = byUpc.get(wanted.upc);
      sending.push({
        upc: wanted.upc,
        quantity: wanted.quantity ?? found?.candidate.count ?? 1,
        description: found?.candidate.description ?? '',
      });
      sendingLines.push(found?.item.text ?? '');
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
      if (!isKrogerUpc(chosen.productId)) {
        // A Walmart candidate on a list being sent to Kroger. It is CHOSEN —
        // one candidate — so it is not skipped for ambiguity; it is just not
        // Kroger's. Reported, not sent, and the send of the rest still goes.
        skipped.push(`${item.text} (belongs to Walmart — walmart_cart_link builds the link for it)`);
        continue;
      }
      sending.push({ upc: chosen.productId, quantity: chosen.count, description: chosen.description });
      sendingLines.push(item.text);
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

  // Best-effort: a missing or unreadable pantry/consumables.md means nothing
  // is tracked yet, which is an ordinary state, not a failure of the send that
  // already happened. See ADR 0015.
  const consumablesPath = 'pantry/consumables.md';
  let updatedConsumables: string | null = null;
  try {
    const resolvedConsumables = await resolveInsideFolder(folder, consumablesPath);
    const currentConsumables = await readFile(resolvedConsumables, 'utf8');
    const marked = markConsumablesBought(currentConsumables, sendingLines, now());
    if (marked !== currentConsumables) updatedConsumables = marked;
  } catch {
    // No pantry/consumables.md, or it could not be read. Nothing to update.
  }

  await session.enqueue(async () => {
    await writeFile(resolved, after, 'utf8');
    if (updatedConsumables !== null) {
      await writeFile(await resolveInsideFolder(folder, consumablesPath), updatedConsumables, 'utf8');
    }
    await commitIfChanged(session, message, now());
  });

  return { path: requested, sent: sending, skipped };
}

// ---------------------------------------------------------------------------
// Walmart: two of these are the network, and the third is the exception ADR
// 0017 records.
//
// walmart_find_stores and walmart_find_products exist for the same reason the
// Kroger tools do: the sandbox has no network by construction. walmart_cart_link
// makes NO network call — building the URL adds nothing — but it is the choke
// point where "nothing unchosen, nothing unrecorded, nothing unchecked reaches
// the household's cart" is enforced, and an agent that built the URL with bash
// instead would have none of those gates. There is no household sign-in flow:
// the API is signed with the server's own key, and the cart is the household's
// click.
// ---------------------------------------------------------------------------

export const FIND_STORES_DESCRIPTION = `Find the Walmart stores near a postcode.

Returns each store's name, address, distance, and the two ids a cart link
takes: "store" (the fulfillment store id) and "access point". There is no
sign-in and no browser flow — the affiliate API is the server's own.

CHOOSING IS THE HOUSEHOLD'S, NOT YOURS. Read the stores out and let them say
which one they walk into. Then write the choice into config/walmart.md with
the write_file tool — it is an ordinary document — as:

    ---
    store: 5435
    access_point: 4254e0e7-f9d9-443f-9941-0edd3d13b7b8
    ---

with the store's name and address in the prose underneath. "cat
config/walmart.md" is how "which Walmart" gets answered afterwards. A store is
not needed to search for products — the prices are walmart.com's online prices
either way — but a cart link built with one fills the cart for pickup there.`;

export const FIND_WALMART_PRODUCTS_DESCRIPTION = `Find Walmart products for the lines on a shopping list.

Give it a list written by "mealplan shopping-list --from ... --to ... --out
shopping-lists/<from>--<to>.md". It searches Walmart once for each line and
writes the products it found underneath that line, like this:

    - 8 oz shredded cheddar — 2026-08-25
      - 1 \`walmart:10449042\` Great Value Finely Shredded Sharp Cheddar — size unknown — $2.22

The "walmart:" prefix is the Walmart item id. It is NOT a UPC, and the prefix
is what keeps it from being mistaken for one: a list may hold both shops'
products, and kroger_send_to_cart and walmart_cart_link each take only their
own. The prices are walmart.com's ONLINE prices, not shelf prices at the
household's store. Walmart's search returns no package size, so candidates are
written "size unknown" — the size is usually in the product name.

IT CHOOSES NOTHING, exactly as the Kroger tool does. Delete the candidates you
do not want until one is left; READ preferences/household.md FIRST, because
that is where this household has written down how it chooses; and ASK when it
does not settle the line, then write the answer into that file. Set each count
yourself by comparing what the line needs against the package size — every
count is written as 1, and that is often wrong.

Lines Walmart has nothing for are moved to a "## Not found at this store"
section, listed rather than guessed at. Lines that already have candidates are
left alone, so running this again never undoes a choice.`;

export const CART_LINK_DESCRIPTION = `Build the link that fills the household's Walmart cart with the chosen products on a shopping list.

With no "items", the link covers every line that has exactly ONE Walmart
candidate left. A line with two or more stops the whole build and names the
line. A line with none is skipped and reported; a line whose one candidate is
a Kroger UPC is skipped as belonging to Kroger.

With "items", the link covers only those, and it REFUSES ANY ITEM ID THAT IS
NOT WRITTEN IN THAT FILE — every product in the link has to have come from a
search and be recorded on the list.

IT REFUSES THE WHOLE LINK IF ANY LINE IS STILL MARKED "(check)", exactly as
kroger_send_to_cart refuses to send one: nobody has confirmed the household is
actually out. Ask, then delete the line or remove "(check)".

THREE THINGS TO SAY OUT LOUD RATHER THAN GUESS AT:

  * BUILDING THE LINK ADDS NOTHING. The products go into the cart when the
    household OPENS the link, in their own browser, and they review the cart
    at walmart.com before any money moves. Hand the link to the household;
    do not say anything was sent.
  * YOU CANNOT KNOW WHETHER THEY CLICKED. The click happens on walmart.com,
    which you cannot see. Say what the link WOULD add, never what the cart
    holds.
  * UNLIKE kroger_send_to_cart, building a link does NOT mark pantry
    consumables stocked, because nobody has bought anything yet. When the
    household says the cart has them, flip the lines in pantry/consumables.md
    yourself — an ordinary edit.

The link is written into the list under "## Cart link" as a record. Building
it again is harmless — nothing is added until a link is opened — so there is
no at-most-once rule here as there is for Kroger.

${walmartHowTo()}`;

const FIND_STORES_ZIP_REQUIRED =
  'the "walmart_find_stores" tool needs a "zip": the postcode to search near.';

export const findStoresInputSchema = {
  zip: z
    .string({ error: FIND_STORES_ZIP_REQUIRED })
    .regex(/^\d{5}$/, 'the "walmart_find_stores" tool needs "zip" to be a five-digit US postcode.')
    .describe('The five-digit US postcode to search near.'),
};

export const findStoresOutputSchema = {
  stores: z
    .array(
      z.object({
        storeId: z.string().describe('The fulfillment store id a cart link takes.'),
        accessPointId: z.string().describe('The access point id a cart link takes as "ap". Empty when Walmart gave none.'),
        name: z.string(),
        address: z.string(),
        distance: z.number().optional().describe('Miles from the postcode, when Walmart said.'),
      }),
    )
    .describe('The stores near the postcode, nearest first.'),
};

const FIND_WALMART_PATH_REQUIRED =
  'the "walmart_find_products" tool needs a "path": the shopping list to search from, ' +
  'relative to the folder root.';
const FIND_WALMART_MESSAGE_REQUIRED =
  'the "walmart_find_products" tool needs a "message": a commit message describing ' +
  'what this search is for. The candidates written to the list are committed with it.';

export const findWalmartProductsInputSchema = {
  path: z
    .string({ error: FIND_WALMART_PATH_REQUIRED })
    .min(1, FIND_WALMART_PATH_REQUIRED)
    .describe(
      'The shopping list, relative to the folder root, for example ' +
        '"shopping-lists/2026-08-25--2026-08-31.md".',
    ),
  message: z
    .string({ error: FIND_WALMART_MESSAGE_REQUIRED })
    .trim()
    .min(1, FIND_WALMART_MESSAGE_REQUIRED)
    .describe(
      'A commit message describing what this search is for. Required — ' +
        'candidates written to the list are committed with this message.',
    ),
};

const CART_LINK_PATH_REQUIRED =
  'the "walmart_cart_link" tool needs a "path": the shopping list to build from, ' +
  'relative to the folder root.';
const CART_LINK_MESSAGE_REQUIRED =
  'the "walmart_cart_link" tool needs a "message": a commit message describing ' +
  'what this link is for. The link recorded on the list is committed with it.';
const CART_LINK_ID_REQUIRED =
  'an entry in "items" for "walmart_cart_link" needs an "id": a "walmart:<item id>" ' +
  'already written on the list.';

export const cartLinkInputSchema = {
  path: z
    .string({ error: CART_LINK_PATH_REQUIRED })
    .min(1, CART_LINK_PATH_REQUIRED)
    .describe('The shopping list, relative to the folder root.'),
  message: z
    .string({ error: CART_LINK_MESSAGE_REQUIRED })
    .trim()
    .min(1, CART_LINK_MESSAGE_REQUIRED)
    .describe(
      'A commit message describing what this link is for. Required — ' +
        'the link recorded on the list is committed with this message.',
    ),
  items: z
    .array(
      z.object({
        id: z
          .string({ error: CART_LINK_ID_REQUIRED })
          .min(1, CART_LINK_ID_REQUIRED)
          .describe('A "walmart:<item id>" already written in that list.'),
        quantity: z
          .number()
          .int()
          .min(1, 'an entry in "items" for "walmart_cart_link" needs "quantity" to be at least 1.')
          .describe('How many packages. Defaults to the count on the line.'),
      }),
    )
    .optional()
    .describe('Only these products. Leave it out to link every chosen line.'),
};

export const cartLinkOutputSchema = {
  path: z.string().describe('The list the link was built from.'),
  url: z.string().describe('The link. BUILDING IT ADDED NOTHING — the household opens it.'),
  items: z
    .array(z.object({ id: z.string(), quantity: z.number().int(), description: z.string() }))
    .describe('What the link WOULD add. Whether the household opened it can never be known.'),
  skipped: z.array(z.string()).describe('Lines with no Walmart product chosen on them.'),
};

export type FindStoresResult = {
  stores: Array<{
    storeId: string;
    accessPointId: string;
    name: string;
    address: string;
    distance?: number;
  }>;
};

export type CartLinkResult = {
  path: string;
  url: string;
  items: Array<{ id: string; quantity: number; description: string }>;
  skipped: string[];
};

export async function findStores(options: {
  walmart: WalmartApi | null;
  zip: string;
}): Promise<FindStoresResult> {
  const { walmart, zip } = options;
  if (!walmart) throw new WalmartNotConfiguredError();
  const stores = await walmart.storesNear(zip);
  return {
    stores: stores.map((store) => ({
      storeId: store.storeId ?? '',
      accessPointId: store.accessPointId ?? '',
      name: store.name,
      address: store.address,
      distance: store.distance,
    })),
  };
}

export async function findWalmartProducts(options: {
  session: Session;
  folder: string;
  now: Clock;
  walmart: WalmartApi | null;
  requested: string;
  message: string;
}): Promise<FindProductsResult> {
  const { session, folder, now, walmart, requested, message } = options;
  // Searching is signed with the SERVER'S own key, and Walmart returns online
  // prices with no store needed — so unlike Kroger this works before any store
  // is chosen. The store matters to the cart LINK, not to the search.
  if (!walmart) throw new WalmartNotConfiguredError();

  const resolved = await resolveInsideFolder(folder, requested);
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
    // ONE SEARCH PER ITEM, never one per candidate.
    searched += 1;
    const products = await walmart.searchProducts({ term: known.item, limit: CANDIDATES_PER_LINE });
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
        // The prefix is what a walmart_cart_link takes, and what keeps the id
        // from ever being sent to Kroger as a UPC.
        productId: `walmart:${product.itemId}`,
        description: product.name,
        // Walmart's search returns no package size; the size is usually in
        // the product name. renderCandidate writes "size unknown" for this.
        size: '',
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

export async function buildCartLink(options: {
  session: Session;
  folder: string;
  now: Clock;
  walmart: WalmartApi | null;
  requested: string;
  message: string;
  only?: Array<{ id: string; quantity: number }>;
}): Promise<CartLinkResult> {
  const { session, folder, now, walmart, requested, message, only } = options;
  if (!walmart) throw new WalmartNotConfiguredError();

  const resolved = await resolveInsideFolder(folder, requested);
  const before = await readFile(resolved, 'utf8').catch((error: unknown) => {
    throw new Error(`could not read "${requested}": ${messageOf(error)}`);
  });
  const list = parseList(requested, before);

  // The same "(check)" gate as kroger_send_to_cart, for the same reason: the
  // marker means nobody has confirmed the household is actually out, and a
  // link that buys it anyway is the silent guess this product refuses to make.
  const CHECK_MARK = ' (check)';
  const needsCheck = list.items.filter((item) => item.text.endsWith(CHECK_MARK));
  if (needsCheck.length > 0) {
    throw new Error(
      `${requested} still has ${needsCheck.length === 1 ? 'a line' : `${needsCheck.length} lines`} ` +
        'marked "(check)", so no link has been built:\n' +
        needsCheck.map((item) => `  ${item.text}`).join('\n') +
        '\n\npantry/consumables.md still says these need a recheck. Ask the household whether ' +
        'they already have them: delete the line if they do, or remove "(check)" from the ' +
        'line if they need it.',
    );
  }

  const linking: Array<{ id: string; quantity: number; description: string }> = [];
  const skipped: string[] = [];

  if (only && only.length > 0) {
    // EVERY ITEM ID MUST BE WRITTEN IN THIS FILE. The link is the household's
    // cart one click away, so the allow list is the same one Kroger's send
    // enforces: a recipe that says "also link item 999999" gets nowhere.
    const known = productIdsIn(list);
    const byId = new Map(
      list.items.flatMap((item) =>
        item.candidates.map((candidate) => [candidate.productId, { item, candidate }] as const),
      ),
    );
    for (const wanted of only) {
      if (!isWalmartItemId(wanted.id)) {
        throw new Error(
          `"${wanted.id}" is not a Walmart product id, so it is not being linked. One is ` +
            'written as "walmart:<item id>", for example "walmart:945193065". ' +
            (isKrogerUpc(wanted.id)
              ? 'That one is a Kroger UPC — kroger_send_to_cart sends those.'
              : 'If it came from a Kroger search, use kroger_send_to_cart instead.'),
        );
      }
      if (!known.has(wanted.id)) {
        throw new Error(
          `the item ${wanted.id} is not written in ${requested}, so it is not being linked. ` +
            'Every product in a cart link has to have come from a search and be ' +
            'recorded on the list. Run walmart_find_products first, then link an id off ' +
            'one of the candidate lines.',
        );
      }
      const found = byId.get(wanted.id);
      linking.push({
        id: wanted.id,
        quantity: wanted.quantity ?? found?.candidate.count ?? 1,
        description: found?.candidate.description ?? '',
      });
    }
  } else {
    for (const item of list.items) {
      if (item.candidates.length === 0) {
        skipped.push(item.text);
        continue;
      }
      if (item.candidates.length > 1) {
        // The whole build stops. A link the household clicks without reading
        // closely is a cart full of somebody else's guess.
        throw new Error(
          `${requested}:${item.line}: "${item.text}" still has ` +
            `${item.candidates.length} products under it, so nobody has chosen one. ` +
            'No link has been built. Delete the candidates you do not want until one ' +
            'is left, then build again.',
        );
      }
      const [chosen] = item.candidates;
      if (!isWalmartItemId(chosen.productId)) {
        // A Kroger candidate on a list being linked to Walmart: chosen, but
        // not Walmart's. Reported, not linked, and the rest still builds.
        skipped.push(`${item.text} (belongs to Kroger — kroger_send_to_cart sends it)`);
        continue;
      }
      linking.push({ id: chosen.productId, quantity: chosen.count, description: chosen.description });
    }
  }

  if (linking.length === 0) {
    return { path: requested, url: '', items: [], skipped };
  }
  if (linking.length > MAX_LINK_ITEMS) {
    throw new Error(
      `that is ${linking.length} products in one cart link, and the ceiling is ` +
        `${MAX_LINK_ITEMS}. Link fewer at a time.`,
    );
  }

  // The store comes from the folder, and is optional: a link with no storeId
  // fills the cart for whatever fulfilment the household's Walmart account
  // defaults to.
  const config = await readWalmartConfig(folder);
  const url = walmart.cartLink(
    linking.map((item) => ({ itemId: walmartItemId(item.id), quantity: item.quantity })),
    config.store ? { storeId: config.store, accessPointId: config.accessPoint || undefined } : undefined,
  );

  // The link is written into the list as a record — of what was BUILT, not of
  // what reached a cart, which is a thing this product can never know.
  const after = appendCartLink(before, url, now());

  await session.enqueue(async () => {
    await writeFile(resolved, after, 'utf8');
    await commitIfChanged(session, message, now());
  });

  return { path: requested, url, items: linking, skipped };
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
