import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export const updatePassword = async (password: { old: string; new: string }): Promise<{ new_password: boolean }> => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.settings_password_path(),
    data: { user: { password: password.old, new_password: password.new } },
  });
  if (!response.ok) throw new ResponseError();
  const json = cast<{ success: false; error: string } | { success: true; new_password: boolean }>(
    await response.json(),
  );
  if (json.success) return json;
  throw new ResponseError(json.error);
};
