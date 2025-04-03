import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

type ServerInfo = { ok: true; serverName: string; serverId: string; username: string } | { ok: false };
export const fetchServerInfo = async (code: string): Promise<ServerInfo> => {
  const response = await request({
    method: "GET",
    url: Routes.server_info_integrations_discord_index_path({ format: "json", code }),
    accept: "json",
  });
  if (response.ok) {
    const responseData = cast<
      { success: true; server_id: string; server_name: string; username: string } | { success: false }
    >(await response.json());
    if (responseData.success) {
      return {
        ok: true,
        serverName: responseData.server_name,
        serverId: responseData.server_id,
        username: responseData.username,
      };
    }
    return { ok: false };
  }
  return { ok: false };
};

export const joinServer = async (
  code: string,
  purchaseId: string,
): Promise<{ ok: true; serverName: string } | { ok: false }> => {
  const response = await request({
    method: "GET",
    url: Routes.join_server_integrations_discord_index_path({ format: "json", code, purchase_id: purchaseId }),
    accept: "json",
  });
  if (response.ok) {
    const responseData = cast<{ success: true; server_name: string } | { success: false }>(await response.json());
    if (responseData.success) {
      return { ok: true, serverName: responseData.server_name };
    }
    return { ok: false };
  }
  return { ok: false };
};

export const leaveServer = async (purchaseId: string): Promise<{ ok: true; serverName: string } | { ok: false }> => {
  const response = await request({
    method: "GET",
    url: Routes.leave_server_integrations_discord_index_path({ format: "json", purchase_id: purchaseId }),
    accept: "json",
  });
  if (response.ok) {
    const responseData = cast<{ success: true; server_name: string } | { success: false }>(await response.json());
    if (responseData.success) {
      return { ok: true, serverName: responseData.server_name };
    }
    return { ok: false };
  }
  return { ok: false };
};
