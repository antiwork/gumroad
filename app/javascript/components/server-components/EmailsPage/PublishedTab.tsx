import React from "react";
import { useLoaderData } from "react-router-dom";
import { cast } from "ts-safe-cast";

import { deleteInstallment, getPublishedInstallments, Pagination, PublishedInstallment } from "$app/data/installments";
import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";
import { formatStatNumber } from "$app/utils/formatStatNumber";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import {
  EditEmailButton,
  EmptyStatePlaceholder,
  Layout,
  NewEmailButton,
  useSearchContext,
  ViewEmailButton,
} from "$app/components/server-components/EmailsPage";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

import publishedPlaceholder from "$assets/images/placeholders/published_posts.png";

export const PublishedTab = () => {
  const data = cast<{ installments: PublishedInstallment[]; pagination: Pagination } | undefined>(useLoaderData());
  const [installments, setInstallments] = React.useState(data?.installments ?? []);
  const [pagination, setPagination] = React.useState(data?.pagination ?? { count: 0, next: null });
  const currentSeller = assertDefined(useCurrentSeller(), "currentSeller is required");
  const [selectedInstallmentId, setSelectedInstallmentId] = React.useState<string | null>(null);
  const [deletingInstallment, setDeletingInstallment] = React.useState<{
    id: string;
    name: string;
    state: "delete-confirmation" | "deleting";
  } | null>(null);
  const [isLoading, setIsLoading] = React.useState(false);
  const selectedInstallment = selectedInstallmentId
    ? (installments.find((i) => i.external_id === selectedInstallmentId) ?? null)
    : null;

  const [query] = useSearchContext();
  const activeFetchRequest = React.useRef<{ cancel: () => void } | null>(null);

  const fetchInstallments = async ({ reset }: { reset: boolean }) => {
    const nextPage = reset ? 1 : pagination.next;
    if (!nextPage) return;
    setIsLoading(true);
    try {
      activeFetchRequest.current?.cancel();
      const request = getPublishedInstallments({ page: nextPage, query });
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
  const debouncedFetchInstallments = useDebouncedCallback(
    (options: { reset: boolean }) => void fetchInstallments(options),
    500,
  );

  useOnChange(() => {
    debouncedFetchInstallments({ reset: true });
  }, [query]);

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
    <Layout selectedTab="published" hasPosts={!!data?.installments.length}>
      <div className="space-y-4 p-4 md:p-8">
        {installments.length > 0 ? (
          <>
            <Table
              aria-live="polite"
              className={classNames(isLoading && "pointer-events-none opacity-50")}
              aria-label="Published"
            >
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
            {pagination.next ? (
              <Button color="primary" disabled={isLoading} onClick={() => void fetchInstallments({ reset: false })}>
                Load more
              </Button>
            ) : null}
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
                  Are you sure you want to delete the email "{deletingInstallment.name}"? Customers who had access will
                  no longer be able to see it. This action cannot be undone.
                </h4>
              </Modal>
            ) : null}
          </>
        ) : (
          <EmptyStatePlaceholder
            title="Connect with your customers."
            description="Post new updates, send email broadcasts, and use powerful automated workflows to connect and grow your audience."
            placeholderImage={publishedPlaceholder}
          />
        )}
      </div>
    </Layout>
  );
};
