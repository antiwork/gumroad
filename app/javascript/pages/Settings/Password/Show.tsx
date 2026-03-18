import { router, useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { SettingPage } from "$app/parsers/settings";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { AuthenticatorSetup } from "$app/components/Settings/PasswordPage/AuthenticatorSetup";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Label } from "$app/components/ui/Label";

const MIN_PASSWORD_LENGTH = 4;
const MAX_PASSWORD_LENGTH = 128;

type PasswordPageProps = {
  settings_pages: SettingPage[];
  require_old_password: boolean;
  show_authenticator_app_settings: boolean;
  authenticator_app_enabled: boolean;
};

export default function PasswordPage() {
  const props = cast<PasswordPageProps>(usePage().props);
  const uid = React.useId();
  const [requireOldPassword, setRequireOldPassword] = React.useState(props.require_old_password);
  const [settingUp, setSettingUp] = React.useState(false);
  const [removingAuthenticatorApp, setRemovingAuthenticatorApp] = React.useState(false);

  const form = useForm({
    user: {
      password: "",
      new_password: "",
    },
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();

    if (form.data.user.new_password.length < MIN_PASSWORD_LENGTH) {
      showAlert("Your new password is too short.", "error");
      return;
    }

    if (form.data.user.new_password.length >= MAX_PASSWORD_LENGTH) {
      showAlert("Your new password is too long.", "error");
      return;
    }

    form.put(Routes.settings_password_path(), {
      preserveScroll: true,
      onSuccess: (response) => {
        if (response.props.new_password) setRequireOldPassword(true);
        form.reset();
      },
    });
  };

  const handleRemoveAuthenticatorApp = asyncVoid(async () => {
    setRemovingAuthenticatorApp(true);

    try {
      const response = await request({
        url: Routes.settings_totp_path(),
        method: "DELETE",
        accept: "json",
      });
      const result = cast<{ success: boolean; error_message?: string }>(await response.json());
      if (!response.ok || !result.success) {
        throw new ResponseError(result.error_message ?? "Sorry, something went wrong. Please try again.");
      }

      showAlert("Authenticator app removed.", "success");
      router.reload();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setRemovingAuthenticatorApp(false);
    }
  });

  return (
    <SettingsLayout currentPage="password" pages={props.settings_pages}>
      <form onSubmit={handleSubmit}>
        <FormSection header={<h2>Change password</h2>}>
          {requireOldPassword ? (
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-old-password`}>Old password</Label>
              </FieldsetTitle>
              <PasswordInput
                id={`${uid}-old-password`}
                value={form.data.user.password}
                onChange={(e) => form.setData("user.password", e.target.value)}
                required
                disabled={form.processing}
              />
            </Fieldset>
          ) : null}
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-new-password`}>{requireOldPassword ? "New password" : "Add password"}</Label>
            </FieldsetTitle>
            <PasswordInput
              id={`${uid}-new-password`}
              value={form.data.user.new_password}
              onChange={(e) => form.setData("user.new_password", e.target.value)}
              required
              disabled={form.processing}
            />
          </Fieldset>
          <Fieldset>
            <div>
              <Button type="submit" color="accent" disabled={form.processing}>
                {form.processing ? "Changing..." : "Change password"}
              </Button>
            </div>
          </Fieldset>
        </FormSection>
      </form>
      {props.show_authenticator_app_settings ? (
        <FormSection header={<h2>Two-factor authentication</h2>}>
          {props.authenticator_app_enabled ? null : (
            <Alert variant="info">
              Use an authenticator app to get verification codes without waiting for an email.
            </Alert>
          )}
          <div className="flex items-center justify-between gap-4">
            <div className="grid gap-2">
              <div className="font-bold">Authenticator app</div>
              <FieldsetDescription>Get verification codes from an app on your device.</FieldsetDescription>
            </div>
            {props.authenticator_app_enabled ? (
              <Button color="danger" outline onClick={handleRemoveAuthenticatorApp} disabled={removingAuthenticatorApp}>
                {removingAuthenticatorApp ? "Removing..." : "Remove"}
              </Button>
            ) : settingUp ? null : (
              <Button color="accent" onClick={() => setSettingUp(true)}>
                Set up
              </Button>
            )}
          </div>
          {settingUp && !props.authenticator_app_enabled ? (
            <AuthenticatorSetup onCancel={() => setSettingUp(false)} />
          ) : null}
        </FormSection>
      ) : null}
    </SettingsLayout>
  );
}
