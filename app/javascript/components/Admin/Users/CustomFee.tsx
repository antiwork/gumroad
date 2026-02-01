import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";

type AdminUserCustomFeeProps = {
  user: User;
};

const AdminUserCustomFee = ({ user }: AdminUserCustomFeeProps) => {
  const initialCustomFee = user.custom_fee_per_thousand ? user.custom_fee_per_thousand / 10 : "";
  const [customFee, setCustomFee] = React.useState(initialCustomFee);

  return (
    <>
      <hr />
      <details>
        <summary>
          <h3>Custom fee</h3>
        </summary>
        <Form
          url={Routes.set_custom_fee_admin_user_path(user.external_id)}
          method="POST"
          confirmMessage={`Are you sure you want to update this user's custom fee?`}
          onSuccess={() => showAlert("Custom fee updated.", "success")}
        >
          {(isLoading) => (
            <Fieldset>
              <div className="flex items-start gap-2">
                <Input
                  name="custom_fee_percent"
                  type="number"
                  inputMode="decimal"
                  min="0"
                  max="100"
                  step="0.1"
                  value={customFee}
                  className="flex-1"
                  onChange={(e) => setCustomFee(e.target.value)}
                  placeholder="Enter a custom fee percentage between 0 and 100. Submit blank to clear existing custom fee."
                />
                <Button type="submit" disabled={isLoading} id="update-custom-fee">
                  {isLoading ? "Submitting..." : "Submit"}
                </Button>
              </div>
              <FieldsetDescription>
                Note: Updated custom fee will apply to new direct (non-discover) sales of the user, but not to future
                charges of their existing memberships.
              </FieldsetDescription>
            </Fieldset>
          )}
        </Form>
      </details>
    </>
  );
};

export default AdminUserCustomFee;
