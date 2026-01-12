import { router, usePage } from "@inertiajs/react";
import { formatDistanceToNow } from "date-fns";
import React from "react";
import { cast } from "ts-safe-cast";

import { DraftInstallment, Pagination } from "$app/data/installments";
import { assertDefined } from "$app/utils/assert";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { EmptyStatePlaceholder } from "$app/components/EmailsPage/EmptyStatePlaceholder";
import { EmailsLayout } from "$app/components/EmailsPage/Layout";
import {
  DeleteEmailModal,
  EmailSheetActions,
  formatAudienceCount,
  LoadMoreButton,
  useAudienceCounts,
} from "$app/components/EmailsPage/shared";
import { useEmailSearch } from "$app/components/EmailsPage/useEmailSearch";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useUserAgentInfo } from "$app/components/UserAgent";

import draftsPlaceholder from "$assets/images/placeholders/draft_posts.png";

type PageProps = {
  installments: DraftInstallment[];
  pagination: Pagination;
  has_posts: boolean;
};

export default function EmailsDrafts() {
  const { installments, pagination, has_posts } = cast<PageProps>(usePage().props);
  const currentSeller = assertDefined(useCurrentSeller(), "currentSeller is required");

  const audienceCounts = useAudienceCounts(installments);

  const [selectedInstallmentId, setSelectedInstallmentId] = React.useState<string | null>(null);
  const selectedInstallment = selectedInstallmentId
    ? (installments.find((i) => i.external_id === selectedInstallmentId) ?? null)
    : null;
  const [deletingInstallment, setDeletingInstallment] = React.useState<{ id: string; name: string } | null>(null);
  const [isLoadingMore, setIsLoadingMore] = React.useState(false);

  const { query, setQuery } = useEmailSearch();

  const handleLoadMore = () => {
    if (!pagination.next) return;
    router.reload({
      data: { page: pagination.next, query: query || undefined },
      only: ["installments", "pagination"],
      onStart: () => setIsLoadingMore(true),
      onFinish: () => setIsLoadingMore(false),
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
                      aria-busy={formatAudienceCount(audienceCounts, installment.external_id) === null}
                      className="whitespace-nowrap"
                    >
                      {formatAudienceCount(audienceCounts, installment.external_id)}
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      {formatDistanceToNow(installment.updated_at)} ago
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            {pagination.next ? <LoadMoreButton isLoading={isLoadingMore} onClick={handleLoadMore} /> : null}
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
                    {formatAudienceCount(audienceCounts, selectedInstallment.external_id)}
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
                <EmailSheetActions
                  installment={selectedInstallment}
                  onDelete={() =>
                    setDeletingInstallment({
                      id: selectedInstallment.external_id,
                      name: selectedInstallment.name,
                    })
                  }
                />
              </Sheet>
            ) : null}
            <DeleteEmailModal installment={deletingInstallment} onClose={() => setDeletingInstallment(null)} />
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
