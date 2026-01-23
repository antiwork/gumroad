import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Form } from "$app/components/server-components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";
import { Pill } from "$app/components/ui/Pill";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";

export const AdminAddCreditForm = ({ user_id }: { user_id: number }) => (
  <Form
    url={Routes.add_credit_admin_user_path(user_id)}
    method="POST"
    confirmMessage="Are you sure you want to add credits?"
    onSuccess={() => showAlert("Successfully added credits.", "success")}
  >
    {(isLoading) => (
      <Fieldset>
        <div className="input-with-button">
          <InputGroup>
            <Pill className="-ml-2 shrink-0">$</Pill>
            <Input type="text" name="credit[credit_amount]" placeholder="10.25" inputMode="decimal" required />
          </InputGroup>
          <Button type="submit" disabled={isLoading}>
            {isLoading ? "Saving..." : "Add credits"}
          </Button>
        </div>
        <FieldsetDescription>Subtract credits by providing a negative value</FieldsetDescription>
      </Fieldset>
    )}
  </Form>
);

export default register({ component: AdminAddCreditForm, propParser: createCast() });
