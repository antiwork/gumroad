import { router, usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { Pagination, ScheduledInstallment } from "$app/data/installments";
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
import { Card, CardContent } from "$app/components/ui/Card";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useUserAgentInfo } from "$app/components/UserAgent";

import scheduledPlaceholder from "$assets/images/placeholders/scheduled_posts.png";

type PageProps = {
  installments: ScheduledInstallment[];
  pagination: Pagination;
  has_posts: boolean;
};

export default function EmailsScheduled() {
  const { installments, pagination, has_posts } = cast<PageProps>(usePage().props);
  const currentSeller = assertDefined(useCurrentSeller(), "currentSeller is required");
  const userAgentInfo = useUserAgentInfo();

  const installmentsByDate = React.useMemo(
    () =>
      installments.reduce<Record<string, ScheduledInstallment[]>>((acc, installment) => {
        const date = new Date(installment.to_be_published_at).toLocaleDateString(userAgentInfo.locale, {
          month: "short",
          day: "numeric",
          year: "numeric",
          timeZone: currentSeller.timeZone.name,
        });
        if (!acc[date]) acc[date] = [];
        acc[date].push(installment);
        return acc;
      }, {}),
    [installments, userAgentInfo.locale, currentSeller.timeZone.name],
  );

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

  return (
    <EmailsLayout selectedTab="scheduled" hasPosts={has_posts} query={query} onQueryChange={setQuery}>
      <div className="space-y-4 p-4 md:p-8">
        {installments.length > 0 ? (
          <>
            {Object.keys(installmentsByDate).map((date) => (
              <Table key={date} aria-live="polite" className="mb-16">
                <TableCaption>Scheduled for {date}</TableCaption>
                <TableHeader>
                  <TableRow>
                    <TableHead>Subject</TableHead>
                    <TableHead>Sent to</TableHead>
                    <TableHead>Audience</TableHead>
                    <TableHead>Delivery Time</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {installmentsByDate[date]?.map((installment) => (
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
                        {new Date(installment.to_be_published_at).toLocaleTimeString(userAgentInfo.locale, {
                          hour: "numeric",
                          minute: "numeric",
                          timeZone: currentSeller.timeZone.name,
                        })}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            ))}
            {pagination.next ? <LoadMoreButton isLoading={isLoadingMore} onClick={handleLoadMore} /> : null}
            {selectedInstallment ? (
              <Sheet open onOpenChange={() => setSelectedInstallmentId(null)}>
                <SheetHeader>{selectedInstallment.name}</SheetHeader>
                <Card>
                  <CardContent>
                    <h5 className="grow font-bold">Sent to</h5>
                    {selectedInstallment.recipient_description}
                  </CardContent>
                  <CardContent>
                    <h5 className="grow font-bold">Audience</h5>
                    {formatAudienceCount(audienceCounts, selectedInstallment.external_id)}
                  </CardContent>
                  <CardContent>
                    <h5 className="grow font-bold">Delivery Time</h5>
                    {new Date(selectedInstallment.to_be_published_at).toLocaleString(userAgentInfo.locale, {
                      month: "short",
                      day: "numeric",
                      year: "numeric",
                      hour: "numeric",
                      minute: "numeric",
                      timeZone: currentSeller.timeZone.name,
                    })}
                  </CardContent>
                </Card>
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
            title="Set it and forget it."
            description="Schedule an email to be sent exactly when you want."
            placeholderImage={scheduledPlaceholder}
          />
        )}
      </div>
    </EmailsLayout>
  );
}
