import * as React from "react";

import { Form } from "$app/components/Admin/Form";

const AdminPausePayoutsForm = ({
  user_external_id,
  onSuccess,
}: {
  user_external_id: string;
  onSuccess: (reason: string) => void;
}) => {
  const [reason, setReason] = React.useState("");
  const onReasonChange = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    setReason(e.target.value);
  };

  const onPauseSuccess = () => {
    onSuccess(reason);
  };

  return (
    <Form
      url={Routes.pause_admin_user_payouts_path(user_external_id)}
      method="POST"
      confirmMessage={`Are you sure you want to pause payouts for user ${user_external_id}?`}
      onSuccess={onPauseSuccess}
    >
      {(isLoading) => (
        <fieldset>
          <div className="flex flex-col gap-2 md:flex-row md:items-end">
            <textarea
              name="pause_payouts[reason]"
              rows={2}
              className="flex-1"
              placeholder="Add a reason for pausing payouts. It'll be displayed to the user on their dashboard."
              value={reason}
              onChange={onReasonChange}
            />
            <button type="submit" className="button" disabled={isLoading}>
              {isLoading ? "Pausing Payouts" : "Pause Payouts"}
            </button>
          </div>
        </fieldset>
      )}
    </Form>
  );
};

export default AdminPausePayoutsForm;
