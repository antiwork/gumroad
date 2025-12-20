import { router, usePage } from "@inertiajs/react";
import { formatDistanceToNow } from "date-fns";
import React from "react";
import { cast } from "ts-safe-cast";

import { DraftInstallment, getAudienceCount, Pagination } from "$app/data/installments";
import { assertDefined } from "$app/utils/assert";
import { formatStatNumber } from "$app/utils/formatStatNumber";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { EmptyStatePlaceholder } from "$app/components/EmailsPage/EmptyStatePlaceholder";
import { EditEmailButton, EmailsLayout, NewEmailButton } from "$app/components/EmailsPage/Layout";
import { ViewEmailButton } from "$app/components/EmailsPage/ViewEmailButton";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useUserAgentInfo } from "$app/components/UserAgent";

import draftsPlaceholder from "$assets/images/placeholders/draft_posts.png";

type AudienceCounts = Map<string, number | "loading" | "failed">;

const audienceCountValue = (audienceCounts: AudienceCounts, installmentId: string) => {
  const count = audienceCounts.get(installmentId);
  return count === undefined || count === "loading"
    ? null
    : count === "failed"
      ? "--"
      : formatStatNumber({ value: count });
};

type PageProps = {
  installments: DraftInstallment[];
  pagination: Pagination;
  has_posts: boolean;
};

export default function EmailsDrafts() {
  const pageProps = cast<PageProps>(usePage().props);
  const { installments, pagination, has_posts } = pageProps;
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

  const urlParams = new URLSearchParams(window.location.search);
  const initialQuery = urlParams.get("query") || "";
  const [query, setQuery] = React.useState(initialQuery);
  const isInitialMount = React.useRef(true);

  const debouncedSearch = useDebouncedCallback((searchQuery: string) => {
    router.get(
      Routes.drafts_emails_path(),
      { query: searchQuery || undefined },
      { preserveState: false, preserveScroll: false },
    );
  }, 500);

  React.useEffect(() => {
    if (isInitialMount.current) {
      isInitialMount.current = false;
      return;
    }
    debouncedSearch(query);
  }, [query]);

  const handleDelete = () => {
    if (!deletingInstallment) return;
    setDeletingInstallment({ ...deletingInstallment, state: "deleting" });
    router.delete(Routes.email_path(deletingInstallment.id), {
      onSuccess: () => {
        setDeletingInstallment(null);
      },
      onError: () => {
        setDeletingInstallment({ ...deletingInstallment, state: "delete-confirmation" });
        showAlert("Sorry, something went wrong. Please try again.", "error");
      },
    });
  };

  const userAgentInfo = useUserAgentInfo();

  return (
    <EmailsLayout selectedTab="drafts" hasPosts={has_posts} query={query} onQueryChange={setQuery}>
      <div className="space-y-4 p-4 md:p-8">
        {installments.length > 0 ? (
          <>
            <Table aria-live="polite" aria-label="Drafts">
              <TableHeader>
                <TableRow>
                  <TableHead>Subject</TableHead>
                  <TableHead>Sent to</TableHead>
                  <TableHead>Audience</TableHead>
                  <TableHead>Last edited</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {installments.map((installment) => (
                  <TableRow
                    key={installment.external_id}
                    aria-selected={installment.external_id === selectedInstallmentId}
                    onClick={() => setSelectedInstallmentId(installment.external_id)}
                  >
                    <TableCell>{installment.name}</TableCell>
                    <TableCell>{installment.recipient_description}</TableCell>
                    <TableCell
                      aria-busy={audienceCountValue(audienceCounts, installment.external_id) === null}
                      className="whitespace-nowrap"
                    >
                      {audienceCountValue(audienceCounts, installment.external_id)}
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      {formatDistanceToNow(installment.updated_at)} ago
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            {pagination.next ? (
              <Button
                color="primary"
                onClick={() => {
                  router.reload({ data: { page: pagination.next } });
                }}
              >
                Load more
              </Button>
            ) : null}
            {selectedInstallment ? (
              <Sheet open onOpenChange={() => setSelectedInstallmentId(null)}>
                <SheetHeader>{selectedInstallment.name}</SheetHeader>
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
                <div className="grid grid-flow-col gap-4">
                  {selectedInstallment.send_emails ? <ViewEmailButton installment={selectedInstallment} /> : null}
                  {selectedInstallment.shown_on_profile ? (
                    <NavigationButton href={selectedInstallment.full_url} target="_blank" rel="noopener noreferrer">
                      <Icon name="file-earmark-medical-fill"></Icon>
                      View post
                    </NavigationButton>
                  ) : null}
                </div>
                <div className="grid grid-flow-col gap-4">
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
              </Sheet>
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
    </EmailsLayout>
  );
}
