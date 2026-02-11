import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Pill } from "$app/components/ui/Pill";

type AdminUserAddCreditProps = {
  user: User;
};

const AdminUserAddCredit = ({ user }: AdminUserAddCreditProps) => (
  <>
    <hr />
    <details>
      <summary>
        <h3>Add credits</h3>
      </summary>
      <Form
        url={Routes.add_credit_admin_user_path(user.external_id)}
        method="POST"
        confirmMessage="Are you sure you want to add credits?"
        onSuccess={() => showAlert("Successfully added credits.", "success")}
      >
        {(isLoading) => (
          <Fieldset>
            <div className="flex gap-2">
              <InputGroup className="flex-1">
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
    </details>
  </>
);

export default AdminUserAddCredit;
