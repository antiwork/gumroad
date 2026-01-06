import { Link, router, usePage } from "@inertiajs/react";
import * as React from "react";

import { SavedUtmLink, SortKey, UtmLinkStats, UtmLinksStats } from "$app/types/utm_link";
import { classNames } from "$app/utils/classNames";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { Skeleton } from "$app/components/Skeleton";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useUserAgentInfo } from "$app/components/UserAgent";
import useRouteLoading from "$app/components/useRouteLoading";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";
import { WithTooltip } from "$app/components/WithTooltip";

import noLinksYetPlaceholder from "$assets/images/placeholders/utm_links_empty.png";
import noLinksFoundPlaceholder from "$assets/images/placeholders/utm_links_not_found.png";

type UtmLinksIndexProps = {
  utm_links: SavedUtmLink[];
  pagination: PaginationProps;
  query: string | null;
  sort: Sort<SortKey> | null;
  utm_links_stats: UtmLinksStats;
};

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

export const extractSortParam = (searchParams: URLSearchParams): Sort<SortKey> | null => {
  const column = searchParams.get("key");
  switch (column) {
    case "link":
    case "date":
    case "source":
    case "medium":
    case "campaign":
    case "clicks":
    case "sales_count":
    case "revenue_cents":
    case "conversion_rate":
      return {
        key: column,
        direction: searchParams.get("direction") === "desc" ? "desc" : "asc",
      };
    default:
      return null;
  }
};

export default function UtmLinksIndex() {
  const {
    utm_links: utmLinks,
    pagination,
    query: initialQuery,
    sort: initialSort,
    utm_links_stats: utmLinksStats,
  } = usePage<UtmLinksIndexProps>().props;
  const isNavigating = useRouteLoading();

  const utmLinksWithStats = utmLinks.map((utmLink) => utmLinkWithStats(utmLink, utmLinksStats[utmLink.id]));
  const [selectedUtmLink, setSelectedUtmLink] = React.useState<SavedUtmLink | null>(null);
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(() => initialSort || { key: "date", direction: "desc" });
  const [deletingUtmLink, setDeletingUtmLink] = React.useState<{
    id: string;
    title: string;
    state: "delete-confirmation" | "deleting";
  } | null>(null);

  const fetchUtmLinksStats = useDebouncedCallback((ids: string[]) => {
    router.reload({
      data: { ids },
      only: ["utm_links_stats"],
      preserveUrl: true,
    });
  }, 500);

  React.useEffect(() => {
    if (utmLinks.length === 0) return;
    const sortKey = sort?.key;
    if (sortKey === "sales_count" || sortKey === "revenue_cents" || sortKey === "conversion_rate") return;
    const ids = utmLinks.flatMap((link) =>
      utmLinkWithStats(link, utmLinksStats[link.id]).sales_count === null ? [link.id] : [],
    );
    if (ids.length === 0) return;

    fetchUtmLinksStats(ids);
  }, [utmLinks, sort]);

  const query = initialQuery ?? "";

  const onChangePage = (newPage: number) => {
    router.reload({ data: { page: newPage } });
  };

  const onSetSort = (newSort: Sort<SortKey> | null) => {
    setSort(newSort);
    router.reload({
      data: {
        key: newSort?.key,
        direction: newSort?.direction,
        page: undefined,
      },
      only: ["utm_links", "pagination", "sort"],
    });
  };

  const thProps = useSortingTableDriver<SortKey>(sort, onSetSort);

  const onSearch = useDebouncedCallback((newQuery: string) => {
    if (query === newQuery) return;

    router.reload({
      data: { query: newQuery.length > 0 ? newQuery : undefined, page: undefined },
      only: ["utm_links", "pagination", "query"],
    });
  }, 500);

  const handleDelete = (id: string) => {
    router.delete(Routes.dashboard_utm_link_path(id), {
      preserveScroll: true,
      onStart: () => setDeletingUtmLink((prev) => prev && { ...prev, state: "deleting" }),
      onSuccess: () => setSelectedUtmLink(null),
      onError: () => showAlert("Failed to delete link. Please try again.", "error"),
      onFinish: () => setDeletingUtmLink(null),
    });
  };

  return (
    <AnalyticsLayout
      selectedTab="utm_links"
      actions={
        <>
          <SearchBoxPopover initialQuery={query} onSearch={onSearch} />
          <NavigationButtonInertia href={Routes.new_dashboard_utm_link_path()} color="accent">
            Create link
          </NavigationButtonInertia>
        </>
      }
    >
      {isNavigating && utmLinks.length === 0 ? (
        <div style={{ justifySelf: "center" }}>
          <LoadingSpinner className="size-20" />
        </div>
      ) : utmLinks.length > 0 ? (
        <section className="p-4 md:p-8">
          <Table aria-live="polite" className={classNames(isNavigating && "pointer-events-none opacity-50")}>
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
                    <UtmLinkActions
                      link={link}
                      onDelete={() =>
                        setDeletingUtmLink({ id: link.id, title: link.title, state: "delete-confirmation" })
                      }
                    />
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
                    <Button color="danger" onClick={() => handleDelete(deletingUtmLink.id)}>
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
            <PlaceholderImage src={noLinksFoundPlaceholder} />
            <h4>No links found for "{query}"</h4>
          </Placeholder>
        </div>
      ) : (
        <div className="p-4 md:p-8">
          <Placeholder>
            <PlaceholderImage src={noLinksYetPlaceholder} />
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

const UtmLinkActions = ({ link, onDelete }: { link: SavedUtmLink; onDelete: () => void }) => {
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
        <div role="menu">
          <Link href={Routes.edit_dashboard_utm_link_path(link.id)} role="menuitem" className="no-underline">
            <Icon name="pencil" />
            &ensp;Edit
          </Link>
          <Link
            href={Routes.new_dashboard_utm_link_path({ copy_from: link.id })}
            role="menuitem"
            className="no-underline"
          >
            <Icon name="outline-duplicate" />
            &ensp;Duplicate
          </Link>
          <div className="danger" role="menuitem" onClick={onDelete}>
            <Icon name="trash2" />
            &ensp;Delete
          </div>
        </div>
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
  const isNavigating = useRouteLoading();

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
        <Link href={Routes.new_dashboard_utm_link_path({ copy_from: utmLink.id })} className="button">
          Duplicate
        </Link>
        <NavigationButtonInertia href={Routes.edit_dashboard_utm_link_path(utmLink.id)} disabled={isNavigating}>
          Edit
        </NavigationButtonInertia>
        <Button color="danger" onClick={onDelete}>
          Delete
        </Button>
      </div>
    </Sheet>
  );
};
