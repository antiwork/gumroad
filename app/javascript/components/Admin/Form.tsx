import * as React from "react";
import { cast } from "ts-safe-cast";

import { ResponseError, assertResponseError, request } from "$app/utils/request";

import { useClientAlert } from "$app/components/ClientAlertProvider";

export const Form = ({
  url,
  method,
  confirmMessage,
  onSuccess,
  children,
  className,
}: {
  url: string;
  method: "POST" | "DELETE";
  confirmMessage: string | false;
  onSuccess: () => void;
  children: (isLoading: boolean) => React.ReactNode;
  className?: string;
}) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const { showAlert } = useClientAlert();

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    // eslint-disable-next-line no-alert
    if (confirmMessage !== false && !confirm(confirmMessage)) {
      return;
    }

    const form = event.currentTarget;
    const formData = new FormData(form);

    const csrfToken = cast<string>($("meta[name=csrf-token]").attr("content"));
    formData.append("authenticity_token", csrfToken);

    setIsLoading(true);

    try {
      const response = await request({
        url,
        method,
        data: formData,
        accept: "json",
      });

      if (!response.ok) {
        const { message } = cast<{ message?: string }>(await response.json());
        throw new ResponseError(message ?? "Something went wrong.");
      }

      form.reset();
      onSuccess();
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <form onSubmit={(e) => void handleSubmit(e)} className={className}>
      {children(isLoading)}
    </form>
  );
};
