import { describe, expect, it, vi } from "vitest";

import { RateLimitError, ResponseError } from "$app/utils/request";

import type { MemberInfo } from "$app/data/settings/team";

vi.mock("$app/utils/request", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/utils/request")>();
  return { ...actual, request: vi.fn() };
});

vi.stubGlobal("Routes", {
  settings_team_invitations_path: (format: string) => `/settings/team/invitations.${format}`,
  resend_invitation_settings_team_invitation_path: (id: string, format: string) =>
    `/settings/team/invitations/${id}/resend_invitation.${format}`,
});

const { request } = vi.mocked(await import("$app/utils/request"));
const { createTeamInvitation, resendInvitation } = await import("$app/data/settings/team");

const INVITATION = { email: "member@example.com", role: "admin" };

const MEMBER: MemberInfo = {
  type: "invitation",
  id: "inv_1",
  name: "",
  email: "member@example.com",
  avatar_url: "",
  is_expired: true,
  role: "admin",
  options: [],
  leave_team_option: null,
};

describe("createTeamInvitation", () => {
  it("returns the server's rate-limit message so the seller is told why the invitation was refused", async () => {
    request.mockRejectedValue(
      new RateLimitError(
        "You've reached the limit of 10 team invitations per hour. You can invite again in 42 minutes.",
        2520,
      ),
    );

    // The settings page renders `error_message` and nothing else: a rejection escaping from here
    // would leave the seller with no explanation for an invitation that was simply never sent.
    await expect(createTeamInvitation(INVITATION)).resolves.toEqual({
      success: false,
      error_message: "You've reached the limit of 10 team invitations per hour. You can invite again in 42 minutes.",
    });
  });

  it("still rejects a plain failure rather than reporting it as an ordinary error message", async () => {
    request.mockRejectedValue(new ResponseError());

    await expect(createTeamInvitation(INVITATION)).rejects.toBeInstanceOf(ResponseError);
  });
});

describe("resendInvitation", () => {
  const jsonResponse = (body: unknown) =>
    ({ ok: true, json: async () => body }) as unknown as Response;

  it("returns the server's validation message so the page does not report a refused resend as sent", async () => {
    request.mockResolvedValue(
      jsonResponse({ success: false, error_message: "Email is associated with an existing team member" }),
    );

    await expect(resendInvitation(MEMBER)).resolves.toEqual({
      success: false,
      error_message: "Email is associated with an existing team member",
    });
  });

  it("reports success when the server resent the invitation", async () => {
    request.mockResolvedValue(jsonResponse({ success: true }));

    await expect(resendInvitation(MEMBER)).resolves.toEqual({ success: true });
  });
});
