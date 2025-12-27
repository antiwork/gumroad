import { Link, router, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { getUtmLinksStats, UtmLinksStats, UtmLinkStats } from "$app/data/utm_links";
import type { SavedUtmLink, SortKey, UtmLinksIndexProps } from "$app/types/utm_link";
import { asyncVoid } from "$app/utils/promise";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { Pagination } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { Skeleton } from "$app/components/Skeleton";
import Placeholder from "$app/components/ui/Placeholder";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";
import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { WithTooltip } from "$app/components/WithTooltip";

import noLinksYetPlaceholder from "$assets/images/placeholders/utm_links_empty.png";
import noLinksFoundPlaceholder from "$assets/images/placeholders/utm_links_not_found.png";

const duplicateLinkPath = (link: SavedUtmLink) => `${Routes.utm_links_dashboard_path()}/new?copy_from=${link.id}`;
const editLinkPath = (link: SavedUtmLink) => `${Routes.utm_links_dashboard_path()}/${link.id}/edit`;

const truncateText = (text: string, maxLength: number) => {
  const truncated = text.length > maxLength ? `${text.slice(0, maxLength)}...` : text;
  return {
    isTruncated: text.length > maxLength,
    truncated,
    original: text,
  };
};

const fixedDecimalPointNumber = (value: number) => +value.toFixed(2);

const utmLinkWithStats = (utmLink: SavedUtmLink, stats?: UtmLinkStats) => {
  if (!stats) return utmLink;
  const link = { ...utmLink };
  link.sales_count ??= stats.sales_count;
  link.revenue_cents ??= stats.revenue_cents;
  link.conversion_rate ??= stats.conversion_rate;
  return link;
};

const extractSortParam = (sort: Sort<SortKey> | null): Sort<SortKey> | null => {
  if (!sort) return null;
  const validKeys: SortKey[] = [
    "link",
    "date",
    "source",
    "medium",
    "campaign",
    "clicks",
    "sales_count",
    "revenue_cents",
    "conversion_rate",
  ];
  if (validKeys.includes(sort.key)) {
    return sort;
  }
  return null;
};

export default function UtmLinksIndex() {
  const props = cast<UtmLinksIndexProps>(usePage().props);
  const { utm_links: utmLinks, pagination, query: initialQuery, sort: initialSort } = props;

  const [isLoading, setIsLoading] = React.useState(false);
  const [utmLinksStats, setUtmLinksStats] = React.useState<UtmLinksStats>({});
  const utmLinksWithStats = utmLinks.map((utmLink) => utmLinkWithStats(utmLink, utmLinksStats[utmLink.id]));
  const [selectedUtmLink, setSelectedUtmLink] = React.useState<SavedUtmLink | null>(null);
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(
    () => extractSortParam(initialSort) || { key: "date", direction: "desc" },
  );
  const [query, setQuery] = React.useState(initialQuery ?? "");
  const [deletingUtmLink, setDeletingUtmLink] = React.useState<{
    id: string;
    title: string;
    state: "delete-confirmation" | "deleting";
  } | null>(null);

  const activeStatsRequest = React.useRef<{ cancel: () => void } | null>(null);
  const debouncedGetUtmLinksStats = useDebouncedCallback((ids: string[]) => {
    activeStatsRequest.current?.cancel();
    asyncVoid(async () => {
      const request = getUtmLinksStats({ ids });
      activeStatsRequest.current = request;
      const stats = await request.response;
      setUtmLinksStats((prev) => ({ ...prev, ...stats }));
    })();
  }, 500);

  React.useEffect(() => {
    if (utmLinks.length === 0) return;
    const sortKey = sort?.key;
    if (sortKey === "sales_count" || sortKey === "revenue_cents" || sortKey === "conversion_rate") return;
    const ids = utmLinks.flatMap((link) =>
      utmLinkWithStats(link, utmLinksStats[link.id]).sales_count === null ? [link.id] : [],
    );
    if (ids.length === 0) return;

    debouncedGetUtmLinksStats(ids);
  }, [utmLinks, sort]);

  const navigateWithParams = (params: { page?: number; query?: string; sort?: Sort<SortKey> | null }) => {
    const newParams: Record<string, string | number | undefined> = {};

    if (params.page !== undefined && params.page > 1) {
      newParams.page = params.page;
    }
    if (params.query !== undefined && params.query.length > 0) {
      newParams.query = params.query;
    }
    if (params.sort !== undefined && params.sort !== null) {
      newParams.key = params.sort.key;
      newParams.direction = params.sort.direction;
    }

    setIsLoading(true);
    router.get(
      Routes.utm_links_dashboard_path(newParams),
      {},
      {
        preserveState: true,
        preserveScroll: true,
        onFinish: () => setIsLoading(false),
      },
    );
  };

  const onChangePage = (newPage: number) => {
    navigateWithParams({ page: newPage, query, sort });
  };

  const onSetSort = (newSort: Sort<SortKey> | null) => {
    setSort(newSort);
    navigateWithParams({ page: 1, query, sort: newSort });
  };

  const thProps = useSortingTableDriver<SortKey>(sort, onSetSort);

  const debouncedSearch = useDebouncedCallback((newQuery: string) => {
    navigateWithParams({ page: 1, query: newQuery, sort });
  }, 500);

  const onSearch = (newQuery: string) => {
    setQuery(newQuery);
    debouncedSearch(newQuery);
  };

  const handleDelete = () => {
    if (!deletingUtmLink) return;

    setDeletingUtmLink({ ...deletingUtmLink, state: "deleting" });
    router.delete(`${Routes.utm_links_dashboard_path()}/${deletingUtmLink.id}`, {
      only: ["utm_links", "pagination", "flash"],
      onSuccess: () => {
        setDeletingUtmLink(null);
        setSelectedUtmLink(null);
      },
      onError: () => {
        setDeletingUtmLink((previous) => (previous ? { ...previous, state: "delete-confirmation" } : previous));
        showAlert("Failed to delete link. Please try again.", "error");
      },
    });
  };

  return (
    <AnalyticsLayout
      selectedTab="utm_links"
      actions={
        <>
          <SearchBoxPopover initialQuery={query} onSearch={onSearch} />
          <Link href={`${Routes.utm_links_dashboard_path()}/new`} className="button accent">
            Create link
          </Link>
        </>
      }
    >
      {isLoading && utmLinks.length === 0 ? (
        <div style={{ justifySelf: "center" }}>
          <LoadingSpinner className="size-20" />
        </div>
      ) : utmLinks.length > 0 ? (
        <section className="p-4 md:p-8">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead {...thProps("link")} style={{ width: "30%" }}>
                  Link
                </TableHead>
                <TableHead {...thProps("source")}>Source</TableHead>
                <TableHead {...thProps("medium")}>Medium</TableHead>
                <TableHead {...thProps("campaign")}>Campaign</TableHead>
                <TableHead {...thProps("clicks")}>Clicks</TableHead>
                <TableHead {...thProps("revenue_cents")}>Revenue</TableHead>
                <TableHead {...thProps("conversion_rate")}>Conversion</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {utmLinksWithStats.map((link) => (
                <TableRow
                  key={link.id}
                  selected={link.id === selectedUtmLink?.id}
                  onClick={() => setSelectedUtmLink(link)}
                >
                  <TableCell>
                    <div>
                      <h4>
                        <TruncatedTextWithTooltip text={link.title} maxLength={35} />
                      </h4>
                      <small>
                        <a href={link.destination_option?.url} target="_blank" rel="noopener noreferrer">
                          <TruncatedTextWithTooltip text={link.destination_option?.label ?? ""} maxLength={35} />
                        </a>
                      </small>
                    </div>
                  </TableCell>
                  <TableCell>
                    <TruncatedTextWithTooltip text={link.source} maxLength={16} />
                  </TableCell>
                  <TableCell>
                    <TruncatedTextWithTooltip text={link.medium} maxLength={16} />
                  </TableCell>
                  <TableCell>
                    <TruncatedTextWithTooltip text={link.campaign} maxLength={16} />
                  </TableCell>
                  <TableCell className="whitespace-nowrap">{link.clicks}</TableCell>
                  <TableCell aria-busy={link.revenue_cents === null} className="whitespace-nowrap">
                    {link.revenue_cents !== null ? (
                      `$${fixedDecimalPointNumber(link.revenue_cents / 100)}`
                    ) : (
                      <Skeleton className="w-16" />
                    )}
                  </TableCell>
                  <TableCell aria-busy={link.conversion_rate === null} className="whitespace-nowrap">
                    {link.conversion_rate !== null ? (
                      `${fixedDecimalPointNumber(link.conversion_rate * 100)}%`
                    ) : (
                      <Skeleton className="w-16" />
                    )}
                  </TableCell>
                  <TableCell>
                    <UtmLinkActions link={link}>
                      <div role="menu">
                        <Link href={editLinkPath(link)} role="menuitem" style={{ textDecoration: "none" }}>
                          <Icon name="pencil" />
                          &ensp;Edit
                        </Link>
                        <Link href={duplicateLinkPath(link)} role="menuitem" style={{ textDecoration: "none" }}>
                          <Icon name="outline-duplicate" />
                          &ensp;Duplicate
                        </Link>
                        <div
                          className="danger"
                          role="menuitem"
                          onClick={() =>
                            setDeletingUtmLink({ id: link.id, title: link.title, state: "delete-confirmation" })
                          }
                        >
                          <Icon name="trash2" />
                          &ensp;Delete
                        </div>
                      </div>
                    </UtmLinkActions>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          {pagination.pages > 1 ? <Pagination onChangePage={onChangePage} pagination={pagination} /> : null}
          {selectedUtmLink ? (
            <UtmLinkDetails
              utmLink={utmLinkWithStats(selectedUtmLink, utmLinksStats[selectedUtmLink.id])}
              onClose={() => setSelectedUtmLink(null)}
              onDelete={() =>
                setDeletingUtmLink({
                  id: selectedUtmLink.id,
                  title: selectedUtmLink.title,
                  state: "delete-confirmation",
                })
              }
            />
          ) : null}
          {deletingUtmLink ? (
            <Modal
              open
              allowClose={deletingUtmLink.state === "delete-confirmation"}
              onClose={() => setDeletingUtmLink(null)}
              title="Delete link?"
              footer={
                <>
                  <Button disabled={deletingUtmLink.state === "deleting"} onClick={() => setDeletingUtmLink(null)}>
                    Cancel
                  </Button>
                  {deletingUtmLink.state === "deleting" ? (
                    <Button color="danger" disabled>
                      Deleting...
                    </Button>
                  ) : (
                    <Button color="danger" onClick={handleDelete}>
                      Delete
                    </Button>
                  )}
                </>
              }
            >
              <h4>Are you sure you want to delete the link "{deletingUtmLink.title}"? This action cannot be undone.</h4>
            </Modal>
          ) : null}
        </section>
      ) : query ? (
        <div className="p-4 md:p-8">
          <Placeholder>
            <figure>
              <img src={noLinksFoundPlaceholder} />
            </figure>
            <h4>No links found for "{query}"</h4>
          </Placeholder>
        </div>
      ) : (
        <div className="p-4 md:p-8">
          <Placeholder>
            <figure>
              <img src={noLinksYetPlaceholder} />
            </figure>
            <h2>No links yet</h2>
            <h4>Use UTM links to track which sources are driving the most conversions and revenue</h4>

            <a href="/help/article/74-the-analytics-dashboard" target="_blank" rel="noreferrer">
              Learn more about UTM tracking
            </a>
          </Placeholder>
        </div>
      )}
    </AnalyticsLayout>
  );
}

const TruncatedTextWithTooltip = ({ text, maxLength }: { text: string; maxLength: number }) => {
  const { truncated, original, isTruncated } = truncateText(text, maxLength);
  return <WithTooltip tip={isTruncated ? original : null}>{truncated}</WithTooltip>;
};

const UtmLinkActions = ({ link, children }: { link: SavedUtmLink; children: React.ReactNode }) => {
  const [open, setOpen] = React.useState(false);

  return (
    <div className="flex flex-wrap gap-3 lg:justify-end" onClick={(e) => e.stopPropagation()}>
      <CopyToClipboard copyTooltip="Copy short link" text={link.short_url}>
        <Button aria-label="Copy link">
          <Icon name="link" />
        </Button>
      </CopyToClipboard>

      <Popover
        open={open}
        onToggle={setOpen}
        aria-label="Open action menu"
        trigger={
          <Button>
            <Icon name="three-dots" />
          </Button>
        }
      >
        {children}
      </Popover>
    </div>
  );
};

const SearchBoxPopover = ({ initialQuery, onSearch }: { initialQuery: string; onSearch: (query: string) => void }) => {
  const [isOpen, setIsOpen] = React.useState(false);
  const searchInputRef = React.useRef<HTMLInputElement>(null);
  const [query, setQuery] = React.useState(initialQuery);

  React.useEffect(() => {
    if (isOpen) searchInputRef.current?.focus();
  }, [isOpen]);

  return (
    <Popover
      open={isOpen}
      onToggle={setIsOpen}
      aria-label="Toggle Search"
      trigger={
        <WithTooltip tip="Search" position="bottom">
          <div className="button">
            <Icon name="solid-search" />
          </div>
        </WithTooltip>
      }
    >
      <div className="input">
        <Icon name="solid-search" />
        <input
          ref={searchInputRef}
          type="text"
          placeholder="Search"
          value={query}
          onChange={(evt) => {
            const newQuery = evt.target.value;
            setQuery(newQuery);
            onSearch(newQuery);
          }}
        />
      </div>
    </Popover>
  );
};

const UtmLinkDetails = ({
  utmLink,
  onClose,
  onDelete,
}: {
  utmLink: SavedUtmLink;
  onClose: () => void;
  onDelete: () => void;
}) => {
  const userAgentInfo = useUserAgentInfo();

  return (
    <Sheet open onOpenChange={onClose}>
      <SheetHeader>{utmLink.title}</SheetHeader>
      <section className="stack">
        <div>
          <h3>Details</h3>
        </div>
        <div>
          <h5>Date</h5>
          {new Date(utmLink.created_at).toLocaleDateString(userAgentInfo.locale, {
            month: "short",
            day: "numeric",
            year: "numeric",
          })}
        </div>
        {utmLink.destination_option ? (
          <div>
            <h5>Destination</h5>
            <a href={utmLink.destination_option.url} target="_blank" rel="noopener noreferrer">
              {utmLink.destination_option.label}
            </a>
          </div>
        ) : null}
        <div>
          <h5>Source</h5>
          {utmLink.source}
        </div>
        <div>
          <h5>Medium</h5>
          {utmLink.medium}
        </div>
        <div>
          <h5>Campaign</h5>
          {utmLink.campaign}
        </div>
        {utmLink.term ? (
          <div>
            <h5>Term</h5>
            {utmLink.term}
          </div>
        ) : null}
        {utmLink.content ? (
          <div>
            <h5>Content</h5>
            {utmLink.content}
          </div>
        ) : null}
      </section>
      <section className="stack">
        <h3>Statistics</h3>
        <div>
          <h5>Clicks</h5>
          {utmLink.clicks}
        </div>
        <div>
          <h5>Sales</h5>
          <div aria-busy={utmLink.sales_count === null} aria-live="polite">
            {utmLink.sales_count !== null ? utmLink.sales_count : <LoadingSpinner />}
          </div>
        </div>
        <div>
          <h5>Revenue</h5>
          <div aria-busy={utmLink.revenue_cents === null} aria-live="polite">
            {utmLink.revenue_cents !== null ? (
              `$${fixedDecimalPointNumber(utmLink.revenue_cents / 100)}`
            ) : (
              <LoadingSpinner />
            )}
          </div>
        </div>
        <div>
          <h5>Conversion rate</h5>
          <div aria-busy={utmLink.conversion_rate === null} aria-live="polite">
            {utmLink.conversion_rate !== null ? (
              `${fixedDecimalPointNumber(utmLink.conversion_rate * 100)}%`
            ) : (
              <LoadingSpinner />
            )}
          </div>
        </div>
      </section>
      <section className="stack">
        <div>
          <h3>Short link</h3>
          <CopyToClipboard text={utmLink.short_url} copyTooltip="Copy short link">
            <Button aria-label="Copy short link">
              <Icon name="link" />
            </Button>
          </CopyToClipboard>
        </div>
        <div>
          <h5>{utmLink.short_url}</h5>
        </div>
      </section>
      <section className="stack">
        <div>
          <h3>UTM link</h3>
          <CopyToClipboard text={utmLink.utm_url} copyTooltip="Copy UTM link">
            <Button aria-label="Copy UTM link">
              <Icon name="link" />
            </Button>
          </CopyToClipboard>
        </div>
        <div>
          <h5>{utmLink.utm_url}</h5>
        </div>
      </section>
      <div style={{ display: "grid", gridAutoFlow: "column", gap: "var(--spacer-4)" }}>
        <Link href={duplicateLinkPath(utmLink)} className="button">
          Duplicate
        </Link>
        <Link href={editLinkPath(utmLink)} className="button">
          Edit
        </Link>
        <Button color="danger" onClick={onDelete}>
          Delete
        </Button>
      </div>
    </Sheet>
  );
};
