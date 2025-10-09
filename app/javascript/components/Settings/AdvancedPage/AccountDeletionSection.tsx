import * as React from "react";
import { cast } from "ts-safe-cast";

import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";

type Props = {
  formatted_balance_to_forfeit_on_account_deletion: string | null;
};

const AccountDeletionSection = (props: Props) => {
  const [showConfirmationModal, setShowConfirmationModal] = React.useState(false);

  const performAccountDeletion = async () => {
    try {
      const response = await request({
        method: "POST",
        accept: "json",
        url: Routes.deactivate_account_path(),
      });
      const responseData = cast<{ success: true } | { success: false; message: string }>(await response.json());
      if (!responseData.success) throw new ResponseError(responseData.message);
      window.location.href = Routes.root_path();
    } catch (e) {
      assertResponseError(e);
      setShowConfirmationModal(false);
      showAlert(e.message, "error");
    }
  };

  return (
    <section className="p-4! md:p-8!">
      <header>
        <h2>Danger Zone</h2>
      </header>
      <p>
        <a href="/help/article/37-how-to-delete-your-gumroad-account" target="_blank" rel="noreferrer">
          Deleting your account
        </a>{" "}
        will permanently delete all of your products and product files, as well as any credit card and payout
        information. You will not be able to restore your account once it's deleted and you will be unsubscribed from
        any memberships. You will also not be able to create a new account with this account's email.
      </p>
      <div>
        <Button color="danger" onClick={() => setShowConfirmationModal(true)}>
          Delete your Gumroad account
        </Button>
      </div>

      <Modal
        open={showConfirmationModal}
        title="Delete account"
        onClose={() => setShowConfirmationModal(false)}
        footer={
          <>
            <Button onClick={() => setShowConfirmationModal(false)}>Cancel</Button>
            <Button color="danger" onClick={() => void performAccountDeletion()}>
              {props.formatted_balance_to_forfeit_on_account_deletion
                ? "Yes, forfeit balance and delete"
                : "Yes, delete my account"}
            </Button>
          </>
        }
      >
        <p>
          {props.formatted_balance_to_forfeit_on_account_deletion
            ? `You have a balance of ${props.formatted_balance_to_forfeit_on_account_deletion}. To delete your account, you will need to forfeit your balance. `
            : null}
          <span>
            Deleting your account will permanently delete all of your products and product files, as well as any credit
            card and payout information. You will not be able to restore your account once it's deleted and you will be
            unsubscribed from any memberships. You will also not be able to create a new account with this account's
            email.
          </span>
        </p>
        <p>
          For more information, see{" "}
          <a href="/help/article/37-how-to-delete-your-gumroad-account" target="_blank" rel="noreferrer">
            here
          </a>
          .
        </p>
      </Modal>
    </section>
  );
};

export default AccountDeletionSection;
