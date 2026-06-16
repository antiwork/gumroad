import typia from "typia";

import { request, ResponseError } from "$app/utils/request";
import { createPasskey, type PasskeyRegistrationOptions } from "$app/utils/webauthn";

export type Passkey = {
  id: string;
  nickname: string;
  created_at: string;
  last_used_at: string | null;
};

export const PASSKEY_ADD_ERROR = "Could not add this passkey. Please try again.";

export const registerPasskey = async (csrfToken?: string): Promise<Passkey> => {
  const headers = csrfToken ? { "X-CSRF-Token": csrfToken } : undefined;

  const optionsResponse = await request({
    url: Routes.registration_options_settings_passkeys_path(),
    method: "POST",
    accept: "json",
    headers,
  });
  const optionsResult = typia.assert<{
    success: boolean;
    options?: PasskeyRegistrationOptions;
    error_message?: string;
  }>(await optionsResponse.json());
  if (!optionsResponse.ok || !optionsResult.success || !optionsResult.options) {
    throw new ResponseError(optionsResult.error_message ?? PASSKEY_ADD_ERROR);
  }

  const credential = await createPasskey(optionsResult.options);

  const createResponse = await request({
    url: Routes.settings_passkeys_path(),
    method: "POST",
    accept: "json",
    data: { credential },
    headers,
  });
  const createResult = typia.assert<{ success: boolean; passkey?: Passkey; error_message?: string }>(
    await createResponse.json(),
  );
  if (!createResponse.ok || !createResult.success || !createResult.passkey) {
    throw new ResponseError(createResult.error_message ?? PASSKEY_ADD_ERROR);
  }

  return createResult.passkey;
};
