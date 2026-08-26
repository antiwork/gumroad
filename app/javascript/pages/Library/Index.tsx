import { Archive, DotsHorizontalRounded, FileCode, Search, Trash } from "@boxicons/react";
import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { deletePurchasedProduct, setPurchaseArchived } from "$app/data/library";
import { ProductNativeType } from "$app/parsers/product";
import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { SellerAnalyticsProps, trackSellerPurchaseEvent } from "$app/utils/user_analytics";

import { Button } from "$app/components/Button";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { Layout } from "$app/components/Library/Layout";
import { Modal } from "$app/components/Modal";
import { Pagination } from "$app/components/Pagination";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { AuthorByline } from "$app/components/Product/AuthorByline";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { CardContent, Card as UICard } from "$app/components/ui/Card";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Menu, MenuItem } from "$app/components/ui/Menu";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { ProductCard, ProductCardFigure, ProductCardFooter, ProductCardHeader } from "$app/components/ui/ProductCard";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";
import { Select as FormSelect } from "$app/components/ui/Select";
import { StretchedLink } from "$app/components/ui/StretchedLink";
import { useAddThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";

import placeholder from "$assets/images/placeholders/library.png";

export type Result = {
  product: {
    name: string;
    creator: { name: string; profile_url: string; avatar_url: string | null } | null;
    thumbnail_url: string | null;
    native_type: ProductNativeType;
  };
  purchase: {
    id: string;
    is_archived: boolean;
    download_url: string | null;
    variants: string | null;
  };
};

export const Card = ({
  result,
  onArchive,
  onDelete,
}: {
  result: Result;
  onArchive: () => void;
  onDelete: (confirm?: boolean) => void;
}) => {
  const { product, purchase } = result;
  const [isPopoverOpen, setIsPopoverOpen] = React.useState(false);

  const toggleArchived = asyncVoid(async () => {
    const data = { purchase_id: result.purchase.id, is_archived: !result.purchase.is_archived };
    try {
      await setPurchaseArchived(data);
      onArchive();
      showAlert(result.purchase.is_archived ? "Product unarchived!" : "Product archived!", "success");
      setIsPopoverOpen(false);
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong.", "error");
    }
  });

  const name = purchase.variants ? `${product.name} - ${purchase.variants}` : product.name;

  return (
    <ProductCard>
      <ProductCardFigure>
        <Thumbnail url={product.thumbnail_url} nativeType={product.native_type} />
      </ProductCardFigure>
      <ProductCardHeader>
        {purchase.download_url ? (
          <StretchedLink href={purchase.download_url} aria-label={name}>
            <h3 itemProp="name">{name}</h3>
          </StretchedLink>
        ) : (
          <h3 itemProp="name">{name}</h3>
        )}
      </ProductCardHeader>
      <ProductCardFooter>
        <div className="flex-1 p-4">
          {product.creator ? (
            <AuthorByline
              name={product.creator.name}
              profileUrl={product.creator.profile_url}
              avatarUrl={product.creator.avatar_url ?? undefined}
            />
          ) : null}
        </div>
        <div className="p-4">
          <Popover open={isPopoverOpen} onOpenChange={setIsPopoverOpen}>
            <PopoverTrigger aria-label="Open product action menu" className="relative">
              <DotsHorizontalRounded className="size-5" />
            </PopoverTrigger>
            <PopoverContent className="border-0 p-0 shadow-none" usePortal>
              <Menu>
                <MenuItem onClick={toggleArchived}>
                  <Archive className="size-5" />
                  {purchase.is_archived ? "Unarchive" : "Archive"}
                </MenuItem>
                <MenuItem variant="danger" onClick={() => onDelete()}>
                  <Trash className="size-5" />
                  Remove from library
                </MenuItem>
              </Menu>
            </PopoverContent>
          </Popover>
        </div>
      </ProductCardFooter>
    </ProductCard>
  );
};

export const DeleteProductModal = ({
  deleting,
  onCancel,
  onDelete,
}: {
  deleting: Result | null;
  onCancel: () => void;
  onDelete: (deleted: Result) => void;
}) => {
  const deletePurchase = asyncVoid(async (result: Result) => {
    try {
      await deletePurchasedProduct({ purchase_id: result.purchase.id });
      onDelete(result);
      showAlert("Removed from your library!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong.", "error");
    }
  });

  return (
    <Modal
      open={!!deleting}
      onClose={onCancel}
      title="Remove from library"
      footer={
        <>
          <Button onClick={onCancel}>Cancel</Button>
          <Button color="danger" onClick={() => deletePurchase(assertDefined(deleting, "Invalid state"))}>
            Confirm
          </Button>
        </>
      }
    >
      <h4>Remove {deleting?.product.name ?? ""} from your library?</h4>
      <p>
        You keep access through your original download link, and our support team can put the card back if you change
        your mind.
      </p>
    </Modal>
  );
};

export type SearchParams = {
  sort: "recently_updated" | "purchase_date";
  query: string;
  creators: string[];
  bundles: string[];
  show_archived_only: boolean;
};

type Props = {
  results: Result[];
  pagination: { page: number; pages: number; from: number; to: number; count: number };
  creators: { id: string; name: string; count: number }[];
  bundles: { id: string; label: string }[];
  bundle_downloads: { id: string; label: string; download_url: string | null }[];
  archived_count: number;
  unarchived_count: number;
  search: SearchParams;
  purchase_analytics: Record<string, SellerAnalyticsProps>;
  receipt_purchases: { id: string; email: string; permalink: string; has_third_party_analytics: boolean }[];
};

export default function LibraryPage() {
  const {
    results,
    pagination,
    creators,
    bundles,
    bundle_downloads: bundleDownloads,
    archived_count: archivedCount,
    unarchived_count: unarchivedCount,
    search,
    purchase_analytics,
    receipt_purchases,
  } = typia.assert<Props>(usePage().props);

  const discoverUrl = useDiscoverUrl();
  const [enteredQuery, setEnteredQuery] = React.useState(search.query);
  // Back/forward navigation swaps props without remounting; realign the input with the
  // committed query so a stale draft doesn't survive the history jump.
  const [prevQuery, setPrevQuery] = React.useState(search.query);
  if (search.query !== prevQuery) {
    setPrevQuery(search.query);
    setEnteredQuery(search.query);
  }

  // Two quick filter clicks would otherwise both build on the props of the page they were
  // clicked from, so the second visit silently reverts the first. Base each navigation and
  // every control's rendered state on the last requested params until that request settles
  // — a ref would fix the request but leave the checkboxes showing stale state, and the
  // toggles derive their next value from what is rendered.
  const [pendingSearch, setPendingSearch] = React.useState<SearchParams | null>(null);
  const activeSearch = pendingSearch ?? search;
  // Counts only the visits navigate() started. An interrupted filter visit must keep the
  // optimistic state when a newer filter click displaced it, but drop it when something
  // else did — router.reload() from an archive/delete also interrupts, and echoes the old
  // search, so trusting the interrupted flag alone would strand the controls permanently.
  const inFlightNavigations = React.useRef(0);

  const navigate = ({ page, ...updates }: Partial<SearchParams> & { page?: number }) => {
    const next = { ...activeSearch, ...updates };
    setPendingSearch(next);
    const data: Record<string, string> = { sort: next.sort };
    if (next.query) data.query = next.query;
    if (next.creators.length > 0) data.creators = next.creators.join(",");
    if (next.bundles.length > 0) data.bundles = next.bundles.join(",");
    if (next.show_archived_only) data.show_archived_only = "true";
    if (page !== undefined && page > 1) data.page = page.toString();
    inFlightNavigations.current += 1;
    router.get(Routes.library_path(), data, {
      preserveState: true,
      preserveScroll: page === undefined,
      onFinish: () => {
        inFlightNavigations.current -= 1;
        // The last navigation to settle hands the controls back to the server's props,
        // whether it succeeded, failed or was displaced by a reload.
        if (inFlightNavigations.current === 0) setPendingSearch(null);
      },
    });
  };

  // Unarchiving the only archived purchase leaves the archived tab empty, so drop back to
  // the main library, like the pre-pagination page did.
  const refreshAfterArchiveChange = () => {
    if (search.show_archived_only && archivedCount === 1) {
      navigate({ show_archived_only: false });
    } else {
      router.reload();
    }
  };

  const isDesktop = useIsAboveBreakpoint("lg");
  const [mobileFiltersExpanded, setMobileFiltersExpanded] = React.useState(false);
  const [showingAllCreators, setShowingAllCreators] = React.useState(false);
  const isLibraryEmpty = archivedCount + unarchivedCount === 0;
  const showArchivedNotice = !isLibraryEmpty && !search.show_archived_only && unarchivedCount === 0;
  const hasParams =
    activeSearch.show_archived_only ||
    activeSearch.query !== "" ||
    activeSearch.creators.length > 0 ||
    activeSearch.bundles.length > 0;
  const [deleting, setDeleting] = React.useState<Result | null>(null);

  const sortUid = React.useId();
  const bundlesUid = React.useId();

  const creatorsSortedByName = React.useMemo(
    () =>
      // Alphabetical order makes a long creator list scannable — buyers with large
      // libraries look for a specific creator by name, not by how many products they
      // own from them (see gumroad-private#1177).
      [...creators].sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" })),
    [creators],
  );

  const deletePurchase = asyncVoid(async (result: Result) => {
    try {
      await deletePurchasedProduct({ purchase_id: result.purchase.id });
      router.reload();
      showAlert("Removed from your library!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong.", "error");
    }
  });

  const url = new URL(useOriginalLocation());
  const addThirdPartyAnalytics = useAddThirdPartyAnalytics();
  useRunOnce(() => {
    const purchaseIds = [
      ...new Set([...url.searchParams.getAll("purchase_id[]"), ...url.searchParams.getAll("purchase_id")]),
    ];
    if (purchaseIds.length === 0) return;

    url.searchParams.delete("purchase_id[]");
    url.searchParams.delete("purchase_id");
    router.replace({ url: url.pathname + url.search, preserveState: true, preserveScroll: true });

    const email = receipt_purchases.find((purchase) => purchase.id === purchaseIds[0])?.email;
    if (email) showAlert(`Your purchase was successful! We sent a receipt to ${email}.`, "success");

    for (const purchaseId of purchaseIds) {
      const analytics = purchase_analytics[purchaseId];
      if (analytics) trackSellerPurchaseEvent(analytics);

      const receiptPurchase = receipt_purchases.find((purchase) => purchase.id === purchaseId);
      if (receiptPurchase?.has_third_party_analytics)
        addThirdPartyAnalytics({
          permalink: receiptPurchase.permalink,
          location: "receipt",
          purchaseId,
        });
    }
  });

  const commitQuery = () => {
    if (enteredQuery !== activeSearch.query) navigate({ query: enteredQuery });
  };

  const handleSearchKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "Enter") commitQuery();
  };

  const shouldShowFilter =
    !showArchivedNotice && (hasParams || archivedCount > 0 || archivedCount + unarchivedCount > 9);

  return (
    <Layout selectedTab="purchases">
      <section className="space-y-4 p-4 md:p-8">
        {isLibraryEmpty || showArchivedNotice ? (
          <Placeholder>
            {isLibraryEmpty ? (
              <>
                <PlaceholderImage src={placeholder} />
                <h2 className="library-header">You haven't bought anything... yet!</h2>
                Once you do, it'll show up here so you can download, watch, read, or listen to all your purchases.
                <Button asChild color="accent">
                  <a href={discoverUrl}>Discover products</a>
                </Button>
              </>
            ) : (
              <>
                <h2 className="library-header">You've archived all your products.</h2>
                <Button
                  color="accent"
                  onClick={(e) => {
                    e.preventDefault();
                    navigate({ show_archived_only: true });
                  }}
                >
                  See archive
                </Button>
              </>
            )}
          </Placeholder>
        ) : null}
        {archivedCount > 0 && !activeSearch.show_archived_only && !showArchivedNotice ? (
          <Alert role="status" variant="info" className="mb-5">
            You have {archivedCount} archived purchase{archivedCount === 1 ? "" : "s"}.{" "}
            <button
              type="button"
              className="cursor-pointer underline all-unset"
              onClick={() => navigate({ show_archived_only: true })}
            >
              Click here to view
            </button>
          </Alert>
        ) : null}
        {bundleDownloads.map((bundleDownload) => (
          <Alert key={bundleDownload.id} role="status" variant="info" className="mb-5 flex items-center gap-4">
            <div className="grow">
              Download everything included in <strong>{bundleDownload.label}</strong> as one ZIP file.
            </div>
            {bundleDownload.download_url ? (
              <Button asChild color="accent">
                <a href={bundleDownload.download_url}>
                  <FileCode pack="filled" className="size-5" />
                  Download all
                </a>
              </Button>
            ) : (
              <Button disabled>
                <FileCode pack="filled" className="size-5" />
                Preparing ZIP
              </Button>
            )}
          </Alert>
        ))}
        <div
          className={classNames(
            "grid grid-cols-1 items-start gap-x-16 gap-y-8",
            shouldShowFilter && "lg:grid-cols-[var(--grid-cols-sidebar)]",
          )}
        >
          {shouldShowFilter ? (
            <UICard className="overflow-y-auto lg:sticky lg:inset-y-4 lg:max-h-[calc(100vh-2rem)]" aria-label="Filters">
              <CardContent asChild>
                <header>
                  <div className="grow">
                    {pagination.count
                      ? `Showing ${pagination.from}-${pagination.to} of ${pagination.count} products`
                      : "No products found"}
                  </div>
                  {isDesktop ? null : (
                    <button
                      className="cursor-pointer underline all-unset"
                      onClick={() => setMobileFiltersExpanded(!mobileFiltersExpanded)}
                    >
                      Filter
                    </button>
                  )}
                </header>
              </CardContent>
              {isDesktop || mobileFiltersExpanded ? (
                <>
                  <CardContent>
                    <InputGroup className="grow">
                      <Search className="size-5 text-muted" />
                      <Input
                        className="search-products"
                        placeholder="Search products"
                        value={enteredQuery}
                        onChange={(e) => setEnteredQuery(e.target.value)}
                        onBlur={commitQuery}
                        onKeyDown={handleSearchKeyDown}
                      />
                    </InputGroup>
                  </CardContent>
                  <CardContent className="sort">
                    <Fieldset className="grow basis-0">
                      <FieldsetTitle>
                        <Label className="filter-header" htmlFor={sortUid}>
                          Sort by
                        </Label>
                      </FieldsetTitle>
                      <FormSelect
                        id={sortUid}
                        value={activeSearch.sort}
                        onChange={(e) =>
                          navigate({ sort: e.target.value === "purchase_date" ? "purchase_date" : "recently_updated" })
                        }
                      >
                        <option value="recently_updated">Recently Updated</option>
                        <option value="purchase_date">Purchase Date</option>
                      </FormSelect>
                    </Fieldset>
                  </CardContent>
                  {bundles.length > 0 ? (
                    <CardContent>
                      <Fieldset className="grow basis-0">
                        <FieldsetTitle>
                          <Label htmlFor={bundlesUid}>Bundles</Label>
                        </FieldsetTitle>
                        <Select
                          inputId={bundlesUid}
                          instanceId={bundlesUid}
                          options={bundles}
                          value={bundles.filter(({ id }) => activeSearch.bundles.includes(id))}
                          onChange={(selectedOptions) => navigate({ bundles: selectedOptions.map(({ id }) => id) })}
                          isMulti
                          isClearable
                        />
                      </Fieldset>
                    </CardContent>
                  ) : null}
                  <CardContent className="creator">
                    <Fieldset role="group" className="grow basis-0">
                      <FieldsetTitle className="filter-header">Creator</FieldsetTitle>
                      <Label className="w-full">
                        All Creators
                        <Checkbox
                          wrapperClassName="ml-auto"
                          checked={activeSearch.creators.length === 0}
                          onClick={() => navigate({ creators: [] })}
                          readOnly
                        />
                      </Label>
                      {(showingAllCreators ? creatorsSortedByName : creatorsSortedByName.slice(0, 5)).map((creator) => (
                        <Label key={creator.id} className="w-full">
                          {creator.name}
                          <span className="shrink-0 text-muted">{`(${creator.count})`}</span>
                          <Checkbox
                            wrapperClassName="ml-auto"
                            checked={activeSearch.creators.includes(creator.id)}
                            onClick={() =>
                              navigate({
                                creators: activeSearch.creators.includes(creator.id)
                                  ? activeSearch.creators.filter((id) => id !== creator.id)
                                  : [...activeSearch.creators, creator.id],
                              })
                            }
                            readOnly
                          />
                        </Label>
                      ))}
                      <div>
                        {creatorsSortedByName.length > 5 && !showingAllCreators ? (
                          <button
                            className="cursor-pointer underline all-unset"
                            onClick={() => setShowingAllCreators(true)}
                          >
                            Show more
                          </button>
                        ) : null}
                      </div>
                    </Fieldset>
                  </CardContent>
                  {archivedCount > 0 ? (
                    <CardContent className="archived">
                      <Fieldset role="group" className="grow basis-0">
                        <Label className="justify-between">
                          Show archived only
                          <Checkbox
                            checked={activeSearch.show_archived_only}
                            readOnly
                            onClick={() => navigate({ show_archived_only: !activeSearch.show_archived_only })}
                          />
                        </Label>
                      </Fieldset>
                    </CardContent>
                  ) : null}
                </>
              ) : null}
            </UICard>
          ) : null}
          <ProductCardGrid>
            {results.map((result) => (
              <Card
                key={result.purchase.id}
                result={result}
                onArchive={refreshAfterArchiveChange}
                onDelete={(confirm = true) => (confirm ? setDeleting(result) : deletePurchase(result))}
              />
            ))}
            {pagination.pages > 1 ? (
              <div className="col-[1/-1]">
                <Pagination
                  pagination={{ pages: pagination.pages, page: pagination.page }}
                  onChangePage={(page) => navigate({ page })}
                />
              </div>
            ) : null}
          </ProductCardGrid>
        </div>
        <DeleteProductModal
          deleting={deleting}
          onCancel={() => setDeleting(null)}
          onDelete={() => {
            router.reload();
            setDeleting(null);
          }}
        />
      </section>
    </Layout>
  );
}
