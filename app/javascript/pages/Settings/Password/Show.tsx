import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { SettingPage } from "$app/parsers/settings";

import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Label } from "$app/components/ui/Label";

const MIN_PASSWORD_LENGTH = 4;
const MAX_PASSWORD_LENGTH = 128;

type PasswordPageProps = {
  settings_pages: SettingPage[];
  require_old_password: boolean;
};

export default function PasswordPage() {
  const props = cast<PasswordPageProps>(usePage().props);
  const uid = React.useId();
  const [requireOldPassword, setRequireOldPassword] = React.useState(props.require_old_password);

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
    </SettingsLayout>
  );
}
