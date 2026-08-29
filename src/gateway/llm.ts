// The exe.dev LLM gateway, from the server process, outside the sandbox.
//
// `fetch` is built into Node 24, so NO PACKAGE IS ADDED HERE — the same choice
// ADR 0010 made for Kroger, and for the same reason: the server's dependencies
// run outside the sandbox, in the process that would hold a credential if this
// call needed one. See ADR 0018.
//
// IT NEEDS NO API KEY. The exe.dev integration authenticates by the VM's own
// network identity, not a bearer token this process has to hold or rotate.
// MEALPLAN_LLM_BASE is the mock seam, the same reasoning as KROGER_API_BASE:
// scenarios share one process, so this is passed as an option, never read from
// process.env at call time.

export const DEFAULT_LLM_BASE = 'https://llm.int.exe.xyz/anthropic';
const ANTHROPIC_VERSION = '2023-06-01';

export type LlmTextBlock = { type: 'text'; text: string };
export type LlmToolUseBlock = { type: 'tool_use'; id: string; name: string; input: unknown };
export type LlmToolResultBlock = {
  type: 'tool_result';
  tool_use_id: string;
  content: string;
  is_error?: boolean;
};
export type LlmContentBlock = LlmTextBlock | LlmToolUseBlock | LlmToolResultBlock;

export type LlmMessage = {
  role: 'user' | 'assistant';
  content: LlmContentBlock[];
};

export type LlmToolSchema = {
  name: string;
  description: string;
  input_schema: unknown;
};

export type LlmRequest = {
  model: string;
  max_tokens: number;
  system: string;
  messages: LlmMessage[];
  tools: LlmToolSchema[];
};

export type LlmResponse = {
  content: LlmContentBlock[];
  stop_reason: 'end_turn' | 'tool_use' | 'max_tokens' | 'stop_sequence' | string;
};

/**
 * One call, Anthropic Messages API shape. No retry, no streaming: a turn in
 * this job's loop is a handful of small documents, not a long generation.
 */
export async function callLlm(base: string, request: LlmRequest): Promise<LlmResponse> {
  const response = await fetch(`${base}/v1/messages`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'anthropic-version': ANTHROPIC_VERSION,
    },
    body: JSON.stringify(request),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`the LLM gateway answered ${response.status}: ${body}`);
  }

  return (await response.json()) as LlmResponse;
}
