import { useForm } from "@inertiajs/react";
import React from "react";

import { SavedInstallment, getAudienceCount } from "$app/data/installments";
import { formatStatNumber } from "$app/utils/formatStatNumber";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { EditEmailButton, NewEmailButton } from "$app/components/EmailsPage/Layout";
import { ViewEmailButton } from "$app/components/EmailsPage/ViewEmailButton";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";

type DeleteEmailModalProps = {
  installment: { id: string; name: string } | null;
  onClose: () => void;
  warningMessage?: string;
};

export const DeleteEmailModal = ({ installment, onClose, warningMessage }: DeleteEmailModalProps) => {
  const form = useForm({});

  const handleDelete = () => {
    if (!installment) return;
    form.delete(Routes.email_path(installment.id), {
      onSuccess: () => {
        onClose();
      },
      onError: () => {
        showAlert("Sorry, something went wrong. Please try again.", "error");
      },
    });
  };

  if (!installment) return null;

  return (
    <Modal
      open
      allowClose={!form.processing}
      onClose={onClose}
      title="Delete email?"
      footer={
        <>
          <Button disabled={form.processing} onClick={onClose}>
            Cancel
          </Button>
          <Button color="danger" disabled={form.processing} onClick={handleDelete}>
            {form.processing ? "Deleting..." : "Delete email"}
          </Button>
        </>
      }
    >
      <h4>
        Are you sure you want to delete the email "{installment.name}"?{" "}
        {warningMessage ?? "This action cannot be undone."}
      </h4>
    </Modal>
  );
};

export type AudienceCounts = Map<string, number | "loading" | "failed">;

export const useAudienceCounts = (installments: { external_id: string }[]) => {
  const [audienceCounts, setAudienceCounts] = React.useState<AudienceCounts>(new Map());

  React.useEffect(() => {
    installments.forEach(
      asyncVoid(async ({ external_id }) => {
        if (audienceCounts.has(external_id)) return;
        setAudienceCounts((prev) => new Map(prev).set(external_id, "loading"));
        try {
          const { count } = await getAudienceCount(external_id);
          setAudienceCounts((prev) => new Map(prev).set(external_id, count));
        } catch (e) {
          assertResponseError(e);
          setAudienceCounts((prev) => new Map(prev).set(external_id, "failed"));
        }
      }),
    );
  }, [installments]);

  return audienceCounts;
};

export const formatAudienceCount = (audienceCounts: AudienceCounts, installmentId: string): string | null => {
  const count = audienceCounts.get(installmentId);
  return count === undefined || count === "loading"
    ? null
    : count === "failed"
      ? "--"
      : formatStatNumber({ value: count });
};

type EmailSheetActionsProps = {
  installment: SavedInstallment;
  onDelete: () => void;
};

export const EmailSheetActions = ({ installment, onDelete }: EmailSheetActionsProps) => (
  <>
    <div className="grid grid-flow-col gap-4">
      {installment.send_emails ? <ViewEmailButton installment={installment} /> : null}
      {installment.shown_on_profile ? (
        <NavigationButton href={installment.full_url} target="_blank" rel="noopener noreferrer">
          <Icon name="file-earmark-medical-fill" />
          View post
        </NavigationButton>
      ) : null}
    </div>
    <div className="grid grid-flow-col gap-4">
      <NewEmailButton copyFrom={installment.external_id} />
      <EditEmailButton id={installment.external_id} />
      <Button color="danger" onClick={onDelete}>
        Delete
      </Button>
    </div>
  </>
);

type LoadMoreButtonProps = {
  isLoading: boolean;
  onClick: () => void;
};

export const LoadMoreButton = ({ isLoading, onClick }: LoadMoreButtonProps) => (
  <Button color="primary" disabled={isLoading} onClick={onClick}>
    {isLoading ? "Loading..." : "Load more"}
  </Button>
);
