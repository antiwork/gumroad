import typia from "typia";

import { request, ResponseError } from "$app/utils/request";

export type ChatRole = "user" | "assistant";

export type ChatMessage = {
  role: ChatRole;
  content: string;
};

// A store change the agent has prepared. It is NOT applied until the seller confirms it, at which
// point we POST it back to the `actions` endpoint. The agent now stages every change as a single
// generic `api_write` (a real Gumroad API call it will replay after confirmation); `summary` is the
// human-readable description shown on the confirmation card, and `params` carries the endpoint id
// plus its path params and body so the server can replay the exact call.
export type ProposedAction = {
  type: "api_write";
  params: Record<string, unknown>;
  summary: string;
};

type SendMessageResponse =
  | { success: true; reply: string; proposed_action: ProposedAction | null }
  | { success: false; error: string };

type ExecuteActionResponse = { success: boolean; message: string };

export const sendAgentMessage = async (
  messages: ChatMessage[],
): Promise<{ reply: string; proposedAction: ProposedAction | null }> => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_agent_messages_path(),
    data: { messages },
  });
  const json = typia.assert<SendMessageResponse>(await response.json());
  if (!json.success) throw new ResponseError(json.error);
  return { reply: json.reply, proposedAction: json.proposed_action };
};

export const executeAgentAction = async (action: ProposedAction): Promise<string> => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_agent_actions_path(),
    data: { type: action.type, params: action.params },
  });
  const json = typia.assert<ExecuteActionResponse>(await response.json());
  if (!json.success) throw new ResponseError(json.message);
  return json.message;
};
