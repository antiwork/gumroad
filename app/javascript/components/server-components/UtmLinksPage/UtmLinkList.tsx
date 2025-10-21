import * as React from "react";
import ReactDOM from "react-dom";
import { Link, useLoaderData, useNavigate, useNavigation, useRevalidator, useSearchParams } from "react-router-dom";
import { cast } from "ts-safe-cast";

import {
  deleteUtmLink,
  SortKey,
  SavedUtmLink,
  UtmLinkStats,
  getUtmLinksStats,
  UtmLinksStats,
} from "$app/data/utm_links";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover } from "$app/components/Popover";
import { Progress } from "$app/components/Progress";
import { showAlert } from "$app/components/server-components/Alert";
import { extractSortParam } from "$app/components/server-components/UtmLinksPage";
import Placeholder from "$app/components/ui/Placeholder";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { Sort, useSortingTableDriver } from "$app/components/useSortingTableDriver";
import { WithTooltip } from "$app/components/WithTooltip";

import noLinksYetPlaceholder from "$assets/images/placeholders/utm_links_empty.png";
import noLinksFoundPlaceholder from "$assets/images/placeholders/utm_links_not_found.png";

const duplicateLinkPath = (link: SavedUtmLink) => `/dashboard/utm_links/new?copy_from=${link.id}`;
const editLinkPath = (link: SavedUtmLink) => `/dashboard/utm_links/${link.id}/edit`;
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

const UtmLinkList = () => {
  const navigation = useNavigation();
  const navigate = useNavigate();
  const revalidator = useRevalidator();
  const { utm_links: utmLinks, pagination } = cast<{ utm_links: SavedUtmLink[]; pagination: PaginationProps }>(
    useLoaderData(),
  );
  const [utmLinksStats, setUtmLinksStats] = React.useState<UtmLinksStats>({});
  const utmLinksWithStats = utmLinks.map((utmLink) => utmLinkWithStats(utmLink, utmLinksStats[utmLink.id]));
  const [selectedUtmLink, setSelectedUtmLink] = React.useState<SavedUtmLink | null>(null);
  const [searchParams, setSearchParams] = useSearchParams();
  const [sort, setSort] = React.useState<Sort<SortKey> | null>(
    () => extractSortParam(searchParams) || { key: "date", direction: "desc" },
  );
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
    const sortKey = extractSortParam(searchParams)?.key;
    if (sortKey === "sales_count" || sortKey === "revenue_cents" || sortKey === "conversion_rate") return;
    const ids = utmLinks.flatMap((link) =>
      utmLinkWithStats(link, utmLinksStats[link.id]).sales_count === null ? [link.id] : [],
    );
    if (ids.length === 0) return;

    debouncedGetUtmLinksStats(ids);
  }, [utmLinks, searchParams]);

  const onChangePage = (newPage: number) => {
    setSearchParams((prevState) => {
      const params = new URLSearchParams(prevState);
      params.set("page", newPage.toString());
      return params;
    });
  };

  const onSetSort = (newSort: Sort<SortKey> | null) => {
    setSearchParams((prevState) => {
      const params = new URLSearchParams(prevState);
      if (pagination.pages >= 1) params.delete("page");
      if (newSort) {
        params.set("key", newSort.key);
        params.set("direction", newSort.direction);
      }
      return params;
    });
    setSort(newSort);
  };

  const thProps = useSortingTableDriver<SortKey>(sort, onSetSort);

  const query = searchParams.get("query") ?? "";

  const onSearch = useDebouncedCallback((newQuery: string) => {
    if (query === newQuery) return;

    setSearchParams((prevState) => {
      const params = new URLSearchParams(prevState);
      if (newQuery.length > 0) {
        params.set("query", newQuery);
      } else {
        params.delete("query");
      }
      params.delete("page");
      return params;
    });
  }, 500);

  return (
    <AnalyticsLayout
      selectedTab="utm_links"
      actions={
        <>
          <SearchBoxPopover initialQuery={query} onSearch={onSearch} />
          <Link to="/dashboard/utm_links/new" className="button accent">
            Create link
          </Link>
        </>
      }
    >
      {navigation.state === "loading" && utmLinks.length === 0 ? (
        <div style={{ justifySelf: "center" }}>
          <Progress width="5rem" />
        </div>
      ) : utmLinks.length > 0 ? (
        <section className="p-4 md:p-8">
          <table>
            <thead>
              <tr>
                <th {...thProps("link")} style={{ width: "30%" }}>
                  Link
                </th>
                <th {...thProps("source")}>Source</th>
                <th {...thProps("medium")}>Medium</th>
                <th {...thProps("campaign")}>Campaign</th>
                <th {...thProps("clicks")}>Clicks</th>
                <th {...thProps("revenue_cents")}>Revenue</th>
                <th {...thProps("conversion_rate")}>Conversion</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {utmLinksWithStats.map((link) => (
                <tr
                  key={link.id}
                  aria-selected={link.id === selectedUtmLink?.id}
                  onClick={() => setSelectedUtmLink(link)}
                >
                  <td data-label="Link">
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
                  </td>
                  <td data-label="Source">
                    <TruncatedTextWithTooltip text={link.source} maxLength={16} />
                  </td>
                  <td data-label="Medium">
                    <TruncatedTextWithTooltip text={link.medium} maxLength={16} />
                  </td>
                  <td data-label="Campaign">
                    <TruncatedTextWithTooltip text={link.campaign} maxLength={16} />
                  </td>
                  <td data-label="Clicks" style={{ whiteSpace: "nowrap" }}>
                    {link.clicks}
                  </td>
                  <td
                    data-label="Revenue"
                    aria-busy={link.revenue_cents === null}
                    aria-live="polite"
                    style={{ whiteSpace: "nowrap" }}
                  >
                    {link.revenue_cents !== null ? `$${fixedDecimalPointNumber(link.revenue_cents / 100)}` : null}
                  </td>
                  <td
                    data-label="Conversion"
                    aria-busy={link.conversion_rate === null}
                    aria-live="polite"
                    style={{ whiteSpace: "nowrap" }}
                  >
                    {link.conversion_rate !== null ? `${fixedDecimalPointNumber(link.conversion_rate * 100)}%` : null}
                  </td>
                  <td>
                    <UtmLinkActions link={link}>
                      <div role="menu">
                        <div role="menuitem" onClick={() => navigate(editLinkPath(link))}>
                          <Icon name="pencil" />
                          &ensp;Edit
                        </div>
                        <div role="menuitem" onClick={() => navigate(duplicateLinkPath(link))}>
                          <Icon name="outline-duplicate" />
                          &ensp;Duplicate
                        </div>
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
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
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
                    <Button
                      color="danger"
                      onClick={asyncVoid(async () => {
                        try {
                          setDeletingUtmLink({ ...deletingUtmLink, state: "deleting" });
                          await deleteUtmLink(deletingUtmLink.id);
                          revalidator.revalidate();
                          showAlert("Link deleted!", "success");
                        } catch (e) {
                          assertResponseError(e);
                          showAlert("Failed to delete link. Please try again.", "error");
                        } finally {
                          setDeletingUtmLink(null);
                          setSelectedUtmLink(null);
                        }
                      })}
                    >
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
};

const TruncatedTextWithTooltip = ({ text, maxLength }: { text: string; maxLength: number }) => {
  const { truncated, original, isTruncated } = truncateText(text, maxLength);
  return <WithTooltip tip={isTruncated ? original : null}>{truncated}</WithTooltip>;
};

const UtmLinkActions = ({ link, children }: { link: SavedUtmLink; children: React.ReactNode }) => {
  const [open, setOpen] = React.useState(false);

  return (
    <div className="actions" onClick={(e) => e.stopPropagation()}>
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

  return ReactDOM.createPortal(
    <aside>
      <header>
        <h2>{utmLink.title}</h2>
        <button className="close" aria-label="Close details" onClick={onClose} />
      </header>
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
            {utmLink.sales_count !== null ? utmLink.sales_count : <Progress width="1rem" />}
          </div>
        </div>
        <div>
          <h5>Revenue</h5>
          <div aria-busy={utmLink.revenue_cents === null} aria-live="polite">
            {utmLink.revenue_cents !== null ? (
              `$${fixedDecimalPointNumber(utmLink.revenue_cents / 100)}`
            ) : (
              <Progress width="1rem" />
            )}
          </div>
        </div>
        <div>
          <h5>Conversion rate</h5>
          <div aria-busy={utmLink.conversion_rate === null} aria-live="polite">
            {utmLink.conversion_rate !== null ? (
              `${fixedDecimalPointNumber(utmLink.conversion_rate * 100)}%`
            ) : (
              <Progress width="1rem" />
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
        <Link to={duplicateLinkPath(utmLink)} className="button">
          {" "}
          Duplicate
        </Link>
        <NavigationButton href={editLinkPath(utmLink)}> Edit</NavigationButton>
        <Button color="danger" onClick={onDelete}>
          Delete
        </Button>
      </div>
    </aside>,
    document.body,
  );
};

export default UtmLinkList;
