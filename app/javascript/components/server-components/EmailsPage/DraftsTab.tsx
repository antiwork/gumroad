import { formatDistanceToNow } from "date-fns";
import React from "react";
import { useLoaderData } from "react-router-dom";
import { cast } from "ts-safe-cast";

import {
  deleteInstallment,
  DraftInstallment,
  getAudienceCount,
  getDraftInstallments,
  Pagination,
} from "$app/data/installments";
import { assertDefined } from "$app/utils/assert";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import {
  AudienceCounts,
  audienceCountValue,
  EditEmailButton,
  EmptyStatePlaceholder,
  Layout,
  NewEmailButton,
  useSearchContext,
  ViewEmailButton,
} from "$app/components/server-components/EmailsPage";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";
import { useUserAgentInfo } from "$app/components/UserAgent";

import draftsPlaceholder from "$assets/images/placeholders/draft_posts.png";

export const DraftsTab = () => {
  const data = cast<{ installments: DraftInstallment[]; pagination: Pagination } | undefined>(useLoaderData());
  const [installments, setInstallments] = React.useState(data?.installments ?? []);
  const [pagination, setPagination] = React.useState(data?.pagination ?? { count: 0, next: null });
  const currentSeller = assertDefined(useCurrentSeller(), "currentSeller is required");
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
  const [selectedInstallmentId, setSelectedInstallmentId] = React.useState<string | null>(null);
  const selectedInstallment = selectedInstallmentId
    ? (installments.find((i) => i.external_id === selectedInstallmentId) ?? null)
    : null;
  const [deletingInstallment, setDeletingInstallment] = React.useState<{
    id: string;
    name: string;
    state: "delete-confirmation" | "deleting";
  } | null>(null);
  const [isLoading, setIsLoading] = React.useState(false);
  const [query] = useSearchContext();
  const activeFetchRequest = React.useRef<{ cancel: () => void } | null>(null);

  const fetchInstallments = async (reset = false) => {
    const nextPage = reset ? 1 : pagination.next;
    if (!nextPage) return;
    setIsLoading(true);
    try {
      activeFetchRequest.current?.cancel();
      const request = getDraftInstallments({ page: nextPage, query });
      activeFetchRequest.current = request;
      const response = await request.response;
      setInstallments(reset ? response.installments : [...installments, ...response.installments]);
      setPagination(response.pagination);
      activeFetchRequest.current = null;
      setIsLoading(false);
    } catch (e) {
      if (e instanceof AbortError) return;
      activeFetchRequest.current = null;
      setIsLoading(false);
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
  };

  const debouncedFetchInstallments = useDebouncedCallback((reset: boolean) => void fetchInstallments(reset), 500);
  useOnChange(() => debouncedFetchInstallments(true), [query]);

  const handleDelete = async () => {
    if (!deletingInstallment) return;
    try {
      setDeletingInstallment({ ...deletingInstallment, state: "deleting" });
      await deleteInstallment(deletingInstallment.id);
      setInstallments(installments.filter((installment) => installment.external_id !== deletingInstallment.id));
      setDeletingInstallment(null);
      showAlert("Email deleted!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
  };

  const userAgentInfo = useUserAgentInfo();

  return (
    <Layout selectedTab="drafts" hasPosts={!!data?.installments?.length}>
      <div className="space-y-4 p-4 md:p-8">
        {installments.length > 0 ? (
          <>
            <table
              aria-label="Drafts"
              style={{ marginBottom: "var(--spacer-4)" }}
              aria-live="polite"
              aria-busy={isLoading}
            >
              <thead>
                <tr>
                  <th>Subject</th>
                  <th>Sent to</th>
                  <th>Audience</th>
                  <th>Last edited</th>
                </tr>
              </thead>
              <tbody>
                {installments.map((installment) => (
                  <tr
                    key={installment.external_id}
                    aria-selected={installment.external_id === selectedInstallmentId}
                    onClick={() => setSelectedInstallmentId(installment.external_id)}
                  >
                    <td data-label="Subject">{installment.name}</td>
                    <td data-label="Sent to">{installment.recipient_description}</td>
                    <td
                      data-label="Audience"
                      aria-busy={audienceCountValue(audienceCounts, installment.external_id) === null}
                      style={{ whiteSpace: "nowrap" }}
                    >
                      {audienceCountValue(audienceCounts, installment.external_id)}
                    </td>
                    <td data-label="Last edited" style={{ whiteSpace: "nowrap" }}>
                      {formatDistanceToNow(installment.updated_at)} ago
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {pagination.next ? (
              <Button color="primary" disabled={isLoading} onClick={() => void fetchInstallments()}>
                Load more
              </Button>
            ) : null}
            {selectedInstallment ? (
              <aside>
                <header>
                  <h2>{selectedInstallment.name}</h2>
                  <button className="close" aria-label="Close" onClick={() => setSelectedInstallmentId(null)} />
                </header>
                <div className="stack">
                  <div>
                    <h5>Sent to</h5>
                    {selectedInstallment.recipient_description}
                  </div>
                  <div>
                    <h5>Audience</h5>
                    {audienceCountValue(audienceCounts, selectedInstallment.external_id)}
                  </div>
                  <div>
                    <h5>Last edited</h5>
                    {new Date(selectedInstallment.updated_at).toLocaleString(userAgentInfo.locale, {
                      month: "short",
                      day: "numeric",
                      year: "numeric",
                      hour: "numeric",
                      minute: "numeric",
                      timeZone: currentSeller.timeZone.name,
                    })}
                  </div>
                </div>
                <div style={{ display: "grid", gridAutoFlow: "column", gap: "var(--spacer-4)" }}>
                  {selectedInstallment.send_emails ? <ViewEmailButton installment={selectedInstallment} /> : null}
                  {selectedInstallment.shown_on_profile ? (
                    <NavigationButton href={selectedInstallment.full_url} target="_blank" rel="noopener noreferrer">
                      <Icon name="file-earmark-medical-fill"></Icon>
                      View post
                    </NavigationButton>
                  ) : null}
                </div>
                <div style={{ display: "grid", gridAutoFlow: "column", gap: "var(--spacer-4)" }}>
                  <NewEmailButton copyFrom={selectedInstallment.external_id} />
                  <EditEmailButton id={selectedInstallment.external_id} />
                  <Button
                    color="danger"
                    onClick={() =>
                      setDeletingInstallment({
                        id: selectedInstallment.external_id,
                        name: selectedInstallment.name,
                        state: "delete-confirmation",
                      })
                    }
                  >
                    Delete
                  </Button>
                </div>
              </aside>
            ) : null}
            {deletingInstallment ? (
              <Modal
                open
                allowClose={deletingInstallment.state === "delete-confirmation"}
                onClose={() => setDeletingInstallment(null)}
                title="Delete email?"
                footer={
                  <>
                    <Button
                      disabled={deletingInstallment.state === "deleting"}
                      onClick={() => setDeletingInstallment(null)}
                    >
                      Cancel
                    </Button>
                    {deletingInstallment.state === "deleting" ? (
                      <Button color="danger" disabled>
                        Deleting...
                      </Button>
                    ) : (
                      <Button color="danger" onClick={() => void handleDelete()}>
                        Delete email
                      </Button>
                    )}
                  </>
                }
              >
                <h4>
                  Are you sure you want to delete the email "{deletingInstallment.name}"? This action cannot be undone.
                </h4>
              </Modal>
            ) : null}
          </>
        ) : (
          <EmptyStatePlaceholder
            title="Manage your drafts"
            description="Drafts allow you to save your emails and send whenever you're ready!"
            placeholderImage={draftsPlaceholder}
          />
        )}
      </div>
    </Layout>
  );
};
