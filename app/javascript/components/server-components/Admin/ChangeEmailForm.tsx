import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Form } from "$app/components/server-components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";

export const AdminChangeEmailForm = ({ user_id, current_email }: { user_id: number; current_email: string | null }) => (
  <Form
    url={Routes.update_email_admin_user_path(user_id)}
    method="POST"
    confirmMessage="Are you sure you want to update this user's email address?"
    onSuccess={() => showAlert("Successfully updated email address.", "success")}
  >
    {(isLoading) => (
      <Fieldset>
        <div style={{ display: "grid", gap: "var(--spacer-3)", gridTemplateColumns: "1fr auto" }}>
          <Input type="email" name="update_email[email_address]" placeholder={current_email ?? ""} required />
          <Button type="submit" disabled={isLoading}>
            {isLoading ? "Updating..." : "Update email"}
          </Button>
        </div>
        <FieldsetDescription>This will update the user's email to this new one!</FieldsetDescription>
      </Fieldset>
    )}
  </Form>
);

export default register({ component: AdminChangeEmailForm, propParser: createCast() });
