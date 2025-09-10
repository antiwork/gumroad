import * as React from "react";
import { createCast } from "ts-safe-cast";

import { updatePassword } from "$app/data/password";
import { SettingPage } from "$app/parsers/settings";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";

const MIN_PASSWORD_LENGTH = 4;
const MAX_PASSWORD_LENGTH = 128;

type Props = {
  settings_pages: SettingPage[];
  require_old_password: boolean;
};
const PasswordPage = (props: Props) => {
  const uid = React.useId();
  const [password, setPassword] = React.useState({ old: "", new: "" });
  const [requireOldPassword, setRequireOldPassword] = React.useState(props.require_old_password);
  const [isSaving, setIsSaving] = React.useState(false);

  return (
    <SettingsLayout currentPage="password" pages={props.settings_pages}>
      <form
        onSubmit={asyncVoid(async (e) => {
          e.preventDefault();

          if (password.new.length < MIN_PASSWORD_LENGTH) {
            showAlert("Your new password is too short.", "error");
            return;
          }

          if (password.new.length >= MAX_PASSWORD_LENGTH) {
            showAlert("Your new password is too long.", "error");
            return;
          }

          setIsSaving(true);

          try {
            const result = await updatePassword(password);
            if (result.new_password) setRequireOldPassword(true);
            setPassword({ old: "", new: "" });

            showAlert("You have successfully changed your password.", "success");
          } catch (e) {
            assertResponseError(e);
            showAlert(e.message, "error");
          }
          setIsSaving(false);
        })}
      >
        <section className="!p-4 md:!p-8">
          <header>
            <h2>Change password</h2>
          </header>
          {requireOldPassword ? (
            <fieldset>
              <legend>
                <label htmlFor={`${uid}-old-password`}>Old password</label>
              </legend>
              <PasswordInput
                id={`${uid}-old-password`}
                value={password.old}
                onChange={(e) => setPassword((prev) => ({ ...prev, old: e.target.value }))}
                required
              />
            </fieldset>
          ) : null}
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-new-password`}>{requireOldPassword ? "New password" : "Add password"}</label>
            </legend>
            <PasswordInput
              id={`${uid}-new-password`}
              value={password.new}
              onChange={(e) => setPassword((prev) => ({ ...prev, new: e.target.value }))}
              required
            />
          </fieldset>
          <fieldset>
            <div>
              <Button type="submit" color="accent" disabled={isSaving}>
                {isSaving ? "Changing..." : "Change password"}
              </Button>
            </div>
          </fieldset>
        </section>
      </form>
    </SettingsLayout>
  );
};

export default register({ component: PasswordPage, propParser: createCast() });
