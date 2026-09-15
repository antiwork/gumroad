import typia from "typia";

import { RateLimitError, request, ResponseError } from "$app/utils/request";

import { Option } from "$app/components/Select";

export const TYPES = ["owner", "membership", "invitation"] as const;
export const ROLES = ["owner", "accountant", "admin", "marketing", "support"] as const;

export type Role = (typeof ROLES)[number];

export type MemberInfo = {
  type: (typeof TYPES)[number];
  id: string;
  name: string;
  email: string;
  avatar_url: string;
  is_expired: boolean;
  role: Role;
  options: Option[];
  leave_team_option: Option | null;
};

export type TeamInvitation = {
  email: string;
  role: string | null;
};

export const createTeamInvitation = async (
  teamInvitation: TeamInvitation,
): Promise<{ success: false; error_message: string } | { success: true }> => {
  try {
    const response = await request({
      method: "POST",
      accept: "json",
      url: Routes.settings_team_invitations_path("json"),
      data: { team_invitation: teamInvitation },
    });
    if (response.ok) {
      return typia.assert<{ success: false; error_message: string } | { success: true }>(await response.json());
    }
  } catch (e) {
    // A refused invitation answers 429, which `request` raises as a RateLimitError carrying the
    // server's own wording; the caller renders only `error_message`, so it has to go there.
    if (!(e instanceof RateLimitError)) throw e;
    return { success: false, error_message: e.message };
  }
  return { success: false, error_message: "Sorry, something went wrong. Please try again." };
};

export const updateMember = async (memberInfo: MemberInfo, role: Role) => {
  const requestInfo =
    memberInfo.type === "invitation"
      ? { url: Routes.settings_team_invitation_path(memberInfo.id, "json"), data: { team_invitation: { role } } }
      : { url: Routes.settings_team_member_path(memberInfo.id, "json"), data: { team_membership: { role } } };
  const response = await request({
    method: "PUT",
    accept: "json",
    ...requestInfo,
  });

  if (!response.ok) throw new ResponseError();
};

export const deleteMember = async (memberInfo: MemberInfo) => {
  const url =
    memberInfo.type === "invitation"
      ? Routes.settings_team_invitation_path(memberInfo.id, "json")
      : Routes.settings_team_member_path(memberInfo.id, "json");
  const response = await request({
    method: "DELETE",
    accept: "json",
    url,
  });

  if (!response.ok) throw new ResponseError();
};

export const resendInvitation = async (memberInfo: MemberInfo) => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.resend_invitation_settings_team_invitation_path(memberInfo.id, "json"),
  });

  if (!response.ok) throw new ResponseError();
};

export const restoreMember = async (memberInfo: MemberInfo) => {
  const url =
    memberInfo.type === "invitation"
      ? Routes.restore_settings_team_invitation_path(memberInfo.id, "json")
      : Routes.restore_settings_team_member_path(memberInfo.id, "json");
  const response = await request({ method: "PUT", accept: "json", url });

  if (!response.ok) throw new ResponseError();
};
