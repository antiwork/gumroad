import React from "react";

import { updateReviewResponse } from "$app/data/customers";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useLoggedInUser } from "$app/components/LoggedInUser";
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
  onChange: (message: string) => void;
  onEditingChange?: (isEditing: boolean) => void;
  buttonProps?: React.ComponentProps<typeof Button>;
}) => {
  const loggedInUser = useLoggedInUser();

  const [isLoading, setIsLoading] = React.useState(false);
  const [message, setMessage] = React.useState(originalMessage ?? "");
  const [isEditing, setIsEditing] = React.useState(false);
  React.useEffect(() => onEditingChange?.(isEditing), [isEditing]);

  const respondToReview = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setIsLoading(true);
    try {
      await updateReviewResponse(purchaseId, message);
      showAlert(originalMessage ? "Response updated successfully!" : "Response submitted successfully!", "success");
      onChange(message);
      setIsEditing(false);
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
        <form onSubmit={(event) => void respondToReview(event)} style={{ display: "grid", gap: "var(--spacer-3)" }}>
          <textarea
            value={message}
            placeholder="Add a response to the review"
            onChange={(event) => setMessage(event.target.value)}
            disabled={isLoading}
            required
            autoFocus
          />
          <Button {...buttonProps} disabled={isLoading} type="submit">
            {originalMessage
              ? isLoading
                ? "Updating..."
                : "Update response"
              : isLoading
                ? "Submitting..."
                : "Submit response"}
          </Button>
        </form>
      ) : (
        <Button {...buttonProps} onClick={() => setIsEditing(true)}>
          {originalMessage ? "Edit response" : "Add response"}
        </Button>
      )}
    </section>
  );
};
