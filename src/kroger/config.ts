// `config/kroger.md` — the half of the Kroger link that lives in the folder.
//
// THE STORE IS IN THE REPOSITORY AND THE CREDENTIAL IS NOT. They are different
// kinds of thing and they belong in different places:
//
//   the store        a preference. The household should be able to `cat` it,
//                    `grep` it and change it, and the agent should be able to
//                    read it without a tool existing for the question. It is
//                    also what makes a week-old shopping list interpretable —
//                    a price is a price at one store.
//   the credential   a secret that spends money. Outside the folder, mode
//                    0600, where nothing in the sandbox can reach it. See
//                    src/kroger/store.ts.
//
// So `cat config/kroger.md` answers "is Kroger set up", and no tool answers it.
// That is the narrow test ADR 0010 sets for a tool existing at all: a tool
// exists only when the sandbox cannot do the job by construction.
//
// The agent can write this file — it is an ordinary document in an ordinary
// folder. That is not a credential capability. The worst it can do is match the
// shopping against the wrong store, and every list carries the store it was
// matched against in its own front matter, so the mistake is visible.

import { commitIfChanged } from '../git/commit.ts';
import { krogerHowTo } from './help.ts';
import type { Clock } from '../git/repository.ts';
import type { Session } from '../sandbox/session.ts';
import { readCorpusFile, writeCorpusFileDirect } from '../corpus/sandbox.ts';

export const KROGER_CONFIG_PATH = 'config/kroger.md';

/** How the shopping is collected. Kroger wants these upper case; we do not. */
export const MODALITIES = ['pickup', 'delivery'] as const;
export type Modality = (typeof MODALITIES)[number];

export type StoreChoice = {
  locationId: string;
  name: string;
  address: string;
  modality: Modality;
};

/**
 * The document, in whichever of its two states.
 *
 * The store name and address are Kroger's text. They are folded onto one line
 * before they go in, because a newline in a store name would end the front
 * matter early and a `---` in one would end it twice.
 */
export function krogerConfigDocument(choice: StoreChoice | null, baseUrl?: string): string {
  // The procedure comes from src/kroger/help.ts, the same text the tool
  // descriptions and the refusals carry. `cat config/kroger.md` is how "is
  // Kroger set up" gets answered, so it is also where "and how do I change it"
  // has to be answered — an agent that has read this file needs nothing else.
  const howTo = `## Connecting, or changing shops

${krogerHowTo(baseUrl)}

The account link is not in this folder and cannot be reached from it. The store
comes back here; the credential does not, and never will.
`;

  if (!choice) {
    return `---
store:
modality: pickup
---

# Kroger

No Kroger account is connected, and no store is chosen.

${howTo}`;
  }

  const name = oneLine(choice.name);
  const address = oneLine(choice.address);
  return `---
store: ${oneLine(choice.locationId)}
modality: ${choice.modality}
---

# Kroger

A Kroger account is connected. The shopping is matched against **${name}**${
    address ? `, ${address}` : ''
  }, for ${choice.modality}.

\`mealplan shopping-list --out shopping-lists/<from>--<to>.md\` writes a list
against this store, and the prices on it are this store's prices.

${howTo}`;
}

/**
 * Write it, and commit it, under one turn of the session.
 *
 * The same pattern write_file uses, for the same reason: a bash command
 * arriving between the write and the commit would be committed under this
 * message, or would race it on .git/index.lock.
 */
export async function writeKrogerConfig(
  session: Session,
  now: Clock,
  choice: StoreChoice | null,
  baseUrl?: string,
): Promise<void> {
  const message = choice
    ? `kroger: shop at ${oneLine(choice.name)} for ${choice.modality}`
    : 'kroger: disconnect the account';

  await session.enqueue(async () => {
    await writeCorpusFileDirect(session, KROGER_CONFIG_PATH, krogerConfigDocument(choice, baseUrl));
    await commitIfChanged(session, message, now());
  });
}

/**
 * The store the folder currently says to shop at.
 *
 * The server reads its own configuration document, and only its front matter.
 * It is not reading a recipe: the corpus parser stays in the CLI, which is what
 * ADR 0007 protects. A missing or empty file is an unconfigured meal plan, not
 * an error — that is the state every folder starts in.
 */
export async function readKrogerConfig(
  session: Session,
): Promise<{ store: string; modality: Modality }> {
  let text = '';
  try {
    text = await readCorpusFile(session, KROGER_CONFIG_PATH);
  } catch {
    /* not there yet */
  }
  const front: Record<string, string> = {};
  const matched = /^---\n([\s\S]*?)\n---/.exec(text);
  for (const line of (matched?.[1] ?? '').split('\n')) {
    const pair = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
    if (pair) front[pair[1]] = pair[2].trim();
  }
  return {
    store: front.store ?? '',
    modality: isModality(front.modality) ? front.modality : 'pickup',
  };
}

export function isModality(value: unknown): value is Modality {
  return typeof value === 'string' && (MODALITIES as readonly string[]).includes(value);
}

function oneLine(text: string): string {
  return text.replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
}
