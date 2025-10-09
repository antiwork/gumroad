import React from "react";

import { updateReviewResponse, deleteReviewResponse } from "$app/data/customers";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";

export const ReviewResponseForm = ({
  message: originalMessage,
  purchaseId,
  onChange,
  onEditingChange,
  buttonProps = { small: false },
}: {
  message: string | undefined;
  purchaseId: string;
  onChange: (response: { message: string } | null) => void;
  onEditingChange?: (isEditing: boolean) => void;
  buttonProps?: React.ComponentProps<typeof Button>;
}) => {
  const loggedInUser = useLoggedInUser();

  const [isLoading, setIsLoading] = React.useState(false);
  const [message, setMessage] = React.useState(originalMessage ?? "");
  const [isEditing, setIsEditing] = React.useState(false);
  const [deleteConfirmation, setDeleteConfirmation] = React.useState(false);
  React.useEffect(() => onEditingChange?.(isEditing), [isEditing]);

  const respondToReview = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setIsLoading(true);
    try {
      await updateReviewResponse(purchaseId, message);
      showAlert(originalMessage ? "Response updated successfully!" : "Response submitted successfully!", "success");
      onChange({ message });
      setIsEditing(false);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };

  const deleteResponse = async () => {
    setIsLoading(true);
    try {
      await deleteReviewResponse(purchaseId);
      showAlert("Response deleted successfully!", "success");
      onChange(null);
      setDeleteConfirmation(false);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };

  if (!loggedInUser?.policies.product_review_response.update) return null;

  return (
    <section>
      {isEditing ? (
        <form onSubmit={(event) => void respondToReview(event)} className="override grid gap-3">
          <textarea
            value={message}
            placeholder="Add a response to the review"
            onChange={(event) => setMessage(event.target.value)}
            disabled={isLoading}
            required
            autoFocus
          />
          <div className="flex w-full gap-3">
            <Button {...buttonProps} disabled={isLoading} type="submit" className="flex-1">
              {originalMessage ? (isLoading ? "Updating..." : "Update") : isLoading ? "Submitting..." : "Submit"}
            </Button>
            <Button {...buttonProps} onClick={() => setIsEditing(false)} className="flex-1">
              Cancel
            </Button>
          </div>
        </form>
      ) : (
        <div className="flex w-full gap-3">
          <Button {...buttonProps} onClick={() => setIsEditing(true)} className="flex-1">
            {originalMessage ? "Edit" : "Add response"}
          </Button>
          {originalMessage ? (
            <Button {...buttonProps} color="danger" onClick={() => setDeleteConfirmation(true)} className="flex-1">
              Delete
            </Button>
          ) : null}
        </div>
      )}
      {deleteConfirmation ? (
        <Modal
          open={deleteConfirmation}
          onClose={() => setDeleteConfirmation(false)}
          title="Delete this response?"
          footer={
            <>
              <Button disabled={isLoading} onClick={() => setDeleteConfirmation(false)}>
                Cancel
              </Button>
              <Button color="danger" disabled={isLoading} onClick={() => void deleteResponse()}>
                {isLoading ? "Deleting..." : "Delete"}
              </Button>
            </>
          }
        >
          <h4>Deleted responses cannot be recovered.</h4>
        </Modal>
      ) : null}
    </section>
  );
};
