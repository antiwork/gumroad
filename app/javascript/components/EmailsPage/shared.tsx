import { Envelope, FileDetail } from "@boxicons/react";
import { router, useForm } from "@inertiajs/react";
import React from "react";

import { SavedInstallment, getAudienceCount, getNonOpenerCount, resendToNonOpeners } from "$app/data/installments";
import { formatStatNumber } from "$app/utils/formatStatNumber";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { EditEmailButton, NewEmailButton } from "$app/components/EmailsPage/Layout";
import { ViewEmailButton } from "$app/components/EmailsPage/ViewEmailButton";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";

// Only purchase-backed posts have per-recipient open tracking, so a resend to non-openers
// is offered for these types alone (follower/affiliate posts have no per-recipient open linkage).
const NON_OPENER_RESEND_TYPES = ["seller", "product", "variant"];

export const canResendToNonOpeners = (installment: SavedInstallment) =>
  installment.display_type === "published" &&
  installment.send_emails &&
  NON_OPENER_RESEND_TYPES.includes(installment.installment_type);

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

export const ResendToNonOpenersButton = ({ installment }: { installment: SavedInstallment }) => {
  const [loadingCount, setLoadingCount] = React.useState(false);
  const [confirming, setConfirming] = React.useState(false);
  const [count, setCount] = React.useState<number | null>(null);
  // Distinguishes "count is null because the audience was too large to count in time"
  // from "count hasn't loaded yet" — the resend still works without a count.
  const [countUnavailable, setCountUnavailable] = React.useState(false);
  const [recentlyResent, setRecentlyResent] = React.useState(false);
  const [audienceFilteredOut, setAudienceFilteredOut] = React.useState(false);
  const [resending, setResending] = React.useState(false);

  const openConfirmation = asyncVoid(async () => {
    if (loadingCount || confirming) return;
    setLoadingCount(true);
    try {
      const {
        count: nonOpenerCount,
        recently_resent,
        audience_filtered_out,
      } = await getNonOpenerCount(installment.external_id);
      setCount(nonOpenerCount);
      setCountUnavailable(nonOpenerCount === null);
      setRecentlyResent(recently_resent);
      setAudienceFilteredOut(audience_filtered_out);
      setConfirming(true);
    } catch (error) {
      assertResponseError(error);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    } finally {
      setLoadingCount(false);
    }
  });

  const handleResend = asyncVoid(async () => {
    setResending(true);
    try {
      await resendToNonOpeners(installment.external_id);
      showAlert("Resending to everyone who hasn't opened this yet. This may take a while.", "success");
      setRecentlyResent(true);
      setConfirming(false);
      router.reload();
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setResending(false);
    }
  });

  const disableResend = resending || recentlyResent || (!countUnavailable && (count === null || count === 0));

  return (
    <>
      <Button disabled={loadingCount} onClick={openConfirmation}>
        <Envelope pack="filled" className="size-5" />
        {loadingCount ? "Loading..." : "Resend to non-openers"}
      </Button>
      {confirming ? (
        <Modal
          open
          allowClose={!resending}
          onClose={() => setConfirming(false)}
          title="Resend to non-openers?"
          footer={
            <>
              <Button disabled={resending} onClick={() => setConfirming(false)}>
                Cancel
              </Button>
              <Button color="accent" disabled={disableResend} onClick={handleResend}>
                {resending ? "Resending..." : "Resend"}
              </Button>
            </>
          }
        >
          <h4>
            {recentlyResent
              ? "You've already resent this to non-openers recently. Try again in 24 hours."
              : countUnavailable
                ? `This will resend "${installment.name}" to everyone who was emailed but hasn't opened it yet. Your audience is too large to preview an exact count.`
                : count === 0
                  ? audienceFilteredOut
                    ? "The remaining unopened recipients are no longer eligible for this email's audience."
                    : "Everyone who was emailed has already opened this."
                  : `This will resend "${installment.name}" to ${formatStatNumber({ value: count ?? 0 })} people who were emailed but haven't opened it yet.`}
          </h4>
        </Modal>
      ) : null}
    </>
  );
};

type EmailSheetActionsProps = {
  installment: SavedInstallment;
  onDelete: () => void;
};

export const EmailSheetActions = ({ installment, onDelete }: EmailSheetActionsProps) => (
  <>
    <div className="grid grid-flow-col gap-4">
      {installment.send_emails ? <ViewEmailButton installment={installment} /> : null}
      {canResendToNonOpeners(installment) ? <ResendToNonOpenersButton installment={installment} /> : null}
      {installment.shown_on_profile ? (
        <NavigationButton href={installment.full_url} target="_blank" rel="noopener noreferrer">
          <FileDetail pack="filled" className="size-5" />
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
