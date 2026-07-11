import * as React from "react";
import typia from "typia";

import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

// Form for creating a "brand" account: a separate Gumroad account (own email,
// username, and brand name) that the current user administers and can switch to
// from the account switcher. On success the server switches the session into the
// new account, so we simply reload into the dashboard.
export const CreateBrandAccountModal = ({ open, onClose }: { open: boolean; onClose: () => void }) => {
  const [name, setName] = React.useState("");
  const [username, setUsername] = React.useState("");
  const [email, setEmail] = React.useState("");
  const [isSubmitting, setIsSubmitting] = React.useState(false);

  const nameUID = React.useId();
  const usernameUID = React.useId();
  const emailUID = React.useId();

  const submit = async () => {
    setIsSubmitting(true);
    try {
      const response = await request({
        method: "POST",
        accept: "json",
        url: Routes.sellers_brand_accounts_path(),
        data: { brand_account: { name, username, email } },
      });
      const responseData = typia.assert<{ success: true } | { success: false; error_message: string }>(
        await response.json(),
      );
      if (!responseData.success) throw new ResponseError(responseData.error_message);
      // The session is already switched into the new brand account; land on its dashboard.
      window.location.href = Routes.dashboard_path();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
      setIsSubmitting(false);
    }
  };

  return (
    <Modal
      open={open}
      title="Create a new Gumroad"
      onClose={onClose}
      footer={
        <>
          <Button onClick={onClose} disabled={isSubmitting}>
            Cancel
          </Button>
          <Button color="accent" onClick={() => void submit()} disabled={isSubmitting || !name || !username || !email}>
            {isSubmitting ? "Creating..." : "Create"}
          </Button>
        </>
      }
    >
      <p>
        A new Gumroad is a separate account with its own brand name, profile, and products. You'll be its admin and can
        switch to it anytime from this menu. Payout settings are configured on the new account.
      </p>
      <fieldset>
        <Label htmlFor={nameUID}>Brand name</Label>
        <Input
          id={nameUID}
          type="text"
          placeholder="The Minimalist Entrepreneur"
          value={name}
          onChange={(evt) => setName(evt.target.value)}
        />
      </fieldset>
      <fieldset>
        <Label htmlFor={usernameUID}>Username</Label>
        <Input
          id={usernameUID}
          type="text"
          placeholder="minimalist"
          value={username}
          onChange={(evt) => setUsername(evt.target.value)}
        />
      </fieldset>
      <fieldset>
        <Label htmlFor={emailUID}>Email</Label>
        <Input
          id={emailUID}
          type="email"
          placeholder="brand@example.com"
          value={email}
          onChange={(evt) => setEmail(evt.target.value)}
        />
        <small>
          Must be different from your account email. We'll send a confirmation link so the new account has its own
          login.
        </small>
      </fieldset>
    </Modal>
  );
};
