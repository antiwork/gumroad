import { InfoCircle } from "@boxicons/react";
import { router, usePage } from "@inertiajs/react";
import React from "react";
import typia from "typia";

import { Pagination, PublishedInstallment } from "$app/data/installments";
import { assertDefined } from "$app/utils/assert";
import { formatStatNumber } from "$app/utils/formatStatNumber";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { EmptyStatePlaceholder } from "$app/components/EmailsPage/EmptyStatePlaceholder";
import { EmailsLayout } from "$app/components/EmailsPage/Layout";
import { DeleteEmailModal, EmailSheetActions, LoadMoreButton } from "$app/components/EmailsPage/shared";
import { useEmailSearch } from "$app/components/EmailsPage/useEmailSearch";
import { Modal } from "$app/components/Modal";
import { Card, CardContent } from "$app/components/ui/Card";
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
  const { installments, pagination, has_posts } = typia.assert<PageProps>(usePage().props);

  const currentSeller = assertDefined(useCurrentSeller(), "currentSeller is required");
  const [selectedInstallmentId, setSelectedInstallmentId] = React.useState<string | null>(null);
  const [deletingInstallment, setDeletingInstallment] = React.useState<{ id: string; name: string } | null>(null);
  const [clickedUrlsInstallmentId, setClickedUrlsInstallmentId] = React.useState<string | null>(null);
  const [isLoadingMore, setIsLoadingMore] = React.useState(false);
  const selectedInstallment = selectedInstallmentId
    ? (installments.find((i) => i.external_id === selectedInstallmentId) ?? null)
    : null;
  const clickedUrlsInstallment = clickedUrlsInstallmentId
    ? (installments.find((i) => i.external_id === clickedUrlsInstallmentId) ?? null)
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
                      <InfoCircle className="size-5" />
                    </WithTooltip>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {installments.map((installment) => (
                  <React.Fragment key={installment.external_id}>
                    <TableRow
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
                          <button
                            type="button"
                            className="cursor-pointer underline decoration-dotted underline-offset-2 all-unset hover:decoration-solid"
                            aria-label={`View clicked URLs for ${installment.name}`}
                            onClick={(e) => {
                              // Clicking the count should only open the clicked-URLs
                              // modal, not also select the row (which opens the
                              // installment detail sheet underneath the modal).
                              e.stopPropagation();
                              setClickedUrlsInstallmentId(installment.external_id);
                            }}
                          >
                            {formatStatNumber({ value: installment.click_count })}
                          </button>
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
                      {/* On mobile every table row renders as its own bordered card, which made each
                          resend sub-row look like a separate email. Below lg we fold the resends into
                          the parent email's card instead; the dedicated sub-rows below stay desktop-only. */}
                      {installment.non_opener_resends.some((resend) => resend.completed) ? (
                        <TableCell className="lg:hidden">
                          <div className="grid gap-1 text-sm text-muted">
                            {installment.non_opener_resends
                              .filter((resend) => resend.completed)
                              .map((resend) => (
                                <div key={`${installment.external_id}-resend-mobile-${resend.requested_at}`}>
                                  ↳ Resend to non-openers —{" "}
                                  {new Date(resend.requested_at).toLocaleDateString(userAgentInfo.locale, {
                                    day: "numeric",
                                    month: "short",
                                    year: "numeric",
                                    timeZone: currentSeller.timeZone.name,
                                  })}
                                  {" · "}
                                  {formatStatNumber({ value: resend.delivery_count })} emailed
                                  {" · "}
                                  {formatStatNumber({ value: resend.open_rate, suffix: "%", placeholder: "n/a" })}{" "}
                                  opened
                                </div>
                              ))}
                          </div>
                        </TableCell>
                      ) : null}
                    </TableRow>
                    {installment.non_opener_resends
                      .filter((resend) => resend.completed)
                      .map((resend) => (
                        <TableRow
                          key={`${installment.external_id}-resend-${resend.requested_at}`}
                          className="max-lg:hidden"
                          selected={installment.external_id === selectedInstallmentId}
                          onClick={() => setSelectedInstallmentId(installment.external_id)}
                        >
                          <TableCell className="pl-8 text-muted">↳ Resend to non-openers</TableCell>
                          <TableCell className="whitespace-nowrap text-muted">
                            {new Date(resend.requested_at).toLocaleDateString(userAgentInfo.locale, {
                              day: "numeric",
                              month: "short",
                              year: "numeric",
                              timeZone: currentSeller.timeZone.name,
                            })}
                          </TableCell>
                          <TableCell className="whitespace-nowrap text-muted">
                            {formatStatNumber({ value: resend.delivery_count })}
                          </TableCell>
                          <TableCell className="whitespace-nowrap text-muted">
                            {formatStatNumber({ value: resend.open_rate, suffix: "%", placeholder: "n/a" })}
                          </TableCell>
                          <TableCell className="whitespace-nowrap text-muted">n/a</TableCell>
                          <TableCell className="whitespace-nowrap text-muted">n/a</TableCell>
                        </TableRow>
                      ))}
                  </React.Fragment>
                ))}
              </TableBody>
            </Table>
            {pagination.next ? <LoadMoreButton isLoading={isLoadingMore} onClick={handleLoadMore} /> : null}
            {selectedInstallment ? (
              <Sheet open onOpenChange={() => setSelectedInstallmentId(null)}>
                <SheetHeader>{selectedInstallment.name}</SheetHeader>
                <Card>
                  <CardContent>
                    <h5>Sent</h5>
                    {new Date(selectedInstallment.published_at).toLocaleString(userAgentInfo.locale, {
                      timeZone: currentSeller.timeZone.name,
                    })}
                  </CardContent>
                  <CardContent>
                    <h5 className="grow font-bold">Emailed</h5>
                    {selectedInstallment.send_emails
                      ? formatStatNumber({ value: selectedInstallment.sent_count })
                      : "n/a"}
                  </CardContent>
                  <CardContent>
                    <h5 className="grow font-bold">Opened</h5>
                    {selectedInstallment.send_emails
                      ? selectedInstallment.open_rate !== null
                        ? `${formatStatNumber({ value: selectedInstallment.open_count })} (${formatStatNumber({ value: selectedInstallment.open_rate, suffix: "%" })})`
                        : formatStatNumber({ value: selectedInstallment.open_rate })
                      : "n/a"}
                  </CardContent>
                  <CardContent>
                    <h5 className="grow font-bold">Clicks</h5>
                    {selectedInstallment.send_emails
                      ? selectedInstallment.click_rate !== null
                        ? `${formatStatNumber({ value: selectedInstallment.click_count })} (${formatStatNumber({ value: selectedInstallment.click_rate, suffix: "%" })})`
                        : formatStatNumber({ value: selectedInstallment.click_rate })
                      : "n/a"}
                  </CardContent>
                  <CardContent>
                    <h5 className="grow font-bold">Views</h5>
                    {formatStatNumber({
                      value: selectedInstallment.view_count,
                      placeholder: "n/a",
                    })}
                  </CardContent>
                  {selectedInstallment.non_opener_resends.length > 0 ? (
                    <CardContent>
                      <h5 className="font-bold">Resends to non-openers</h5>
                      <ul className="mt-1 grid gap-1">
                        {selectedInstallment.non_opener_resends.map((resend, i) => (
                          <li key={i} className="text-sm">
                            {new Date(resend.requested_at).toLocaleString(userAgentInfo.locale, {
                              timeZone: currentSeller.timeZone.name,
                            })}
                            {resend.completed
                              ? ` — ${formatStatNumber({ value: resend.delivery_count })} emailed${
                                  resend.open_rate !== null
                                    ? `, ${formatStatNumber({ value: resend.open_rate, suffix: "%" })} opened`
                                    : ""
                                }`
                              : " — in progress"}
                          </li>
                        ))}
                      </ul>
                    </CardContent>
                  ) : null}
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
            {clickedUrlsInstallment ? (
              <Modal
                open
                title="Clicked URLs"
                onClose={() => setClickedUrlsInstallmentId(null)}
                className="w-full max-w-2xl"
              >
                <p className="text-muted">{clickedUrlsInstallment.name}</p>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>URL</TableHead>
                      <TableHead className="text-right">Clicks</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {clickedUrlsInstallment.clicked_urls.map(({ url, count }) => (
                      <TableRow key={url}>
                        <TableCell className="break-all whitespace-normal">{url}</TableCell>
                        <TableCell className="text-right whitespace-nowrap">
                          {formatStatNumber({ value: count })}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </Modal>
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
