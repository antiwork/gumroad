import { router, usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { Pagination, PublishedInstallment } from "$app/data/installments";
import { assertDefined } from "$app/utils/assert";
import { formatStatNumber } from "$app/utils/formatStatNumber";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { EmptyStatePlaceholder } from "$app/components/EmailsPage/EmptyStatePlaceholder";
import { EmailsLayout } from "$app/components/EmailsPage/Layout";
import { DeleteEmailModal, EmailSheetActions, LoadMoreButton } from "$app/components/EmailsPage/shared";
import { useEmailSearch } from "$app/components/EmailsPage/useEmailSearch";
import { Icon } from "$app/components/Icons";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

import publishedPlaceholder from "$assets/images/placeholders/published_posts.png";

type PageProps = {
  installments: PublishedInstallment[];
  pagination: Pagination;
  has_posts: boolean;
};

export default function EmailsPublished() {
  const { installments, pagination, has_posts } = cast<PageProps>(usePage().props);

  const currentSeller = assertDefined(useCurrentSeller(), "currentSeller is required");
  const [selectedInstallmentId, setSelectedInstallmentId] = React.useState<string | null>(null);
  const [deletingInstallment, setDeletingInstallment] = React.useState<{ id: string; name: string } | null>(null);
  const [isLoadingMore, setIsLoadingMore] = React.useState(false);
  const selectedInstallment = selectedInstallmentId
    ? (installments.find((i) => i.external_id === selectedInstallmentId) ?? null)
    : null;

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
    <EmailsLayout selectedTab="published" hasPosts={has_posts} query={query} onQueryChange={setQuery}>
      <div className="space-y-4 p-4 md:p-8">
        {installments.length > 0 ? (
          <>
            <Table aria-live="polite" aria-label="Published">
              <TableHeader>
                <TableRow>
                  <TableHead>Subject</TableHead>
                  <TableHead>Date</TableHead>
                  <TableHead>Emailed</TableHead>
                  <TableHead>Opened</TableHead>
                  <TableHead>Clicks</TableHead>
                  <TableHead>
                    Views{" "}
                    <WithTooltip
                      position="top"
                      tip="Views only apply to emails published on your profile."
                      className="whitespace-normal"
                    >
                      <Icon name="info-circle" />
                    </WithTooltip>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {installments.map((installment) => (
                  <TableRow
                    key={installment.external_id}
                    selected={installment.external_id === selectedInstallmentId}
                    onClick={() => setSelectedInstallmentId(installment.external_id)}
                  >
                    <TableCell>{installment.name}</TableCell>
                    <TableCell className="whitespace-nowrap">
                      {new Date(installment.published_at).toLocaleDateString(userAgentInfo.locale, {
                        day: "numeric",
                        month: "short",
                        year: "numeric",
                        timeZone: currentSeller.timeZone.name,
                      })}
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      {installment.send_emails ? formatStatNumber({ value: installment.sent_count }) : "n/a"}
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      {installment.send_emails
                        ? formatStatNumber({ value: installment.open_rate, suffix: "%" })
                        : "n/a"}
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      {installment.clicked_urls.length > 0 ? (
                        <WithTooltip
                          tooltipProps={{ className: "w-[20rem] p-0" }}
                          tip={
                            <Table>
                              <TableBody>
                                {installment.clicked_urls.map(({ url, count }) => (
                                  <TableRow key={`${installment.external_id}-${url}`} className="bg-transparent">
                                    <TableHead scope="row" className="max-w-56 whitespace-break-spaces">
                                      {url}
                                    </TableHead>
                                    <TableCell>{formatStatNumber({ value: count })}</TableCell>
                                  </TableRow>
                                ))}
                              </TableBody>
                            </Table>
                          }
                        >
                          {formatStatNumber({ value: installment.click_count })}
                        </WithTooltip>
                      ) : (
                        formatStatNumber({ value: installment.click_count })
                      )}
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      {formatStatNumber({
                        value: installment.view_count,
                        placeholder: "n/a",
                      })}
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
                    <h5>Sent</h5>
                    {new Date(selectedInstallment.published_at).toLocaleString(userAgentInfo.locale, {
                      timeZone: currentSeller.timeZone.name,
                    })}
                  </div>
                  <div>
                    <h5>Emailed</h5>
                    {selectedInstallment.send_emails
                      ? formatStatNumber({ value: selectedInstallment.sent_count })
                      : "n/a"}
                  </div>
                  <div>
                    <h5>Opened</h5>
                    {selectedInstallment.send_emails
                      ? selectedInstallment.open_rate !== null
                        ? `${formatStatNumber({ value: selectedInstallment.open_count })} (${formatStatNumber({ value: selectedInstallment.open_rate, suffix: "%" })})`
                        : formatStatNumber({ value: selectedInstallment.open_rate })
                      : "n/a"}
                  </div>
                  <div>
                    <h5>Clicks</h5>
                    {selectedInstallment.send_emails
                      ? selectedInstallment.click_rate !== null
                        ? `${formatStatNumber({ value: selectedInstallment.click_count })} (${formatStatNumber({ value: selectedInstallment.click_rate, suffix: "%" })})`
                        : formatStatNumber({ value: selectedInstallment.click_rate })
                      : "n/a"}
                  </div>
                  <div>
                    <h5>Views</h5>
                    {formatStatNumber({
                      value: selectedInstallment.view_count,
                      placeholder: "n/a",
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
            <DeleteEmailModal
              installment={deletingInstallment}
              onClose={() => setDeletingInstallment(null)}
              warningMessage="Customers who had access will no longer be able to see it. This action cannot be undone."
            />
          </>
        ) : (
          <EmptyStatePlaceholder
            title="Connect with your customers."
            description="Post new updates, send email broadcasts, and use powerful automated workflows to connect and grow your audience."
            placeholderImage={publishedPlaceholder}
          />
        )}
      </div>
    </EmailsLayout>
  );
}
