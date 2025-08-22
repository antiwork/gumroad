import React from "react";
import { register } from "$app/utils/serverComponentUtil";
import { createCast } from "ts-safe-cast";
import { Layout } from "../../CheckoutDashboard/Layout";
import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { Pagination } from "$app/components/Pagination";
import { Modal } from "$app/components/Modal";
import { useSortingTableDriver } from "$app/components/useSortingTableDriver";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useUserAgentInfo } from "$app/components/UserAgent";

import { showAlert } from "$app/components/server-components/Alert";
import { assertResponseError } from "$app/utils/request";
import { asyncVoid } from "$app/utils/promise";
import { extractParams, setUrlQueryParams } from "$app/utils/url";
import {
  getPagedDiscountCollections,
  createDiscountCollection,
  updateDiscountCollection,
  deleteDiscountCollection,
  bulkCreateCodes,
  type DiscountCollection,
  type SortKey,
  type Sort,
  type PaginationProps,
} from "$app/data/discount_collection";
import { DiscountCollectionForm } from "./DiscountCollectionForm";
// @ts-ignore
import { BulkCreateCodesForm } from "./BulkCreateCodesForm";
import placeholder from "$assets/images/placeholders/DiscountCollections.png";

type QueryParams = {
  page?: number;
  query?: string | null;
  sort?: Sort<SortKey> | null;
};

type DiscountCollectionsPageProps = {
  discount_collections: DiscountCollection[];
  pages: ("form" | "discounts" | "discount_collections" | "upsells")[];
  pagination: PaginationProps;
  products: Array<{
    id: string;
    name: string;
    archived: boolean;
    currency_type: string;
    is_tiered_membership: boolean;
  }>;
};

const year = new Date().getFullYear();

const DiscountCollectionsPage = ({
  discount_collections: initialDiscountCollections,
  pages,
  pagination: initialPagination,
  products,
}: DiscountCollectionsPageProps) => {
  const [view, setView] = React.useState<"list" | "create" | "edit" | "bulk_create">("list");
  const [selectedCollectionId, setSelectedCollectionId] = React.useState<string | null>(null);
  const [discountCollections, setDiscountCollections] = React.useState(initialDiscountCollections);
  const [pagination, setPagination] = React.useState(initialPagination);
  const [popoverCollectionId, setPopoverCollectionId] = React.useState<string | null>(null);
  const [isLoading, setIsLoading] = React.useState(false);
  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);

  const originalLocation = useOriginalLocation();
  const initialQueryParams = extractParams(new URL(originalLocation).searchParams);

  const [sort, setSort] = React.useState<Sort<SortKey> | null>(
    initialQueryParams.sort && ['name', 'created_at', 'offer_codes_count'].includes(initialQueryParams.sort.key)
      ? initialQueryParams.sort as Sort<SortKey>
      : null
  );
  const thProps = useSortingTableDriver<SortKey>(sort, (newSort) => {
    loadDiscountCollections({ page: 1, query: searchQuery, sort: newSort });
    setSort(newSort);
  });

  const [searchQuery, setSearchQuery] = React.useState<string | null>(initialQueryParams.query);
  const [isSearchPopoverOpen, setIsSearchPopoverOpen] = React.useState(false);
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);

  // Confirmation dialog state
  const [deleteConfirmation, setDeleteConfirmation] = React.useState<{
    collectionId: string;
    collectionName: string;
    offerCodesCount: number;
  } | null>(null);

  const loadDiscountCollections = asyncVoid(async ({ page, query, sort, keepUrl }: QueryParams & { keepUrl?: boolean }) => {
    try {
      activeRequest.current?.cancel();
      setIsLoading(true);

      if (!keepUrl)
        setUrlQueryParams({
          query: query ?? null,
          sort: sort ?? null,
          page: pagination.pages > 1 ? page ?? null : null,
        });

      const request = getPagedDiscountCollections(page || 1, query ?? null, sort ?? null);
      activeRequest.current = request;

      const response = await request.response;
      const { discount_collections: collections, pagination: newPagination } = await response.json();
      setDiscountCollections(collections);
      setPagination(newPagination);
      setIsLoading(false);
      activeRequest.current = null;
    } catch (e) {
      if (e instanceof Error && e.name === 'AbortError') return;
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  // Removed unused function

  const debouncedLoadDiscountCollections = useDebouncedCallback(() => loadDiscountCollections({ page: 1, query: searchQuery, sort }), 300);

  React.useEffect(() => {
    if (isSearchPopoverOpen) searchInputRef.current?.focus();
  }, [isSearchPopoverOpen]);

  const deleteCollection = async (id: string) => {
    try {
      setIsLoading(true);
      await deleteDiscountCollection(id);

      // Remove the deleted collection from the local state immediately
      setDiscountCollections(prev => prev.filter(collection => collection.id !== id));

      // Also update the pagination count
      setPagination(prev => ({
        ...prev,
        count: Math.max(0, prev.count - 1)
      }));

      showAlert("Successfully deleted discount collection!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  const currentSeller = useCurrentSeller();
  if (!currentSeller) return null;

  const userAgentInfo = useUserAgentInfo();

  const formatDateTime = (date: Date) =>
    date.toLocaleDateString(userAgentInfo.locale, {
      month: "short",
      day: "numeric",
      year: date.getFullYear() !== year ? "numeric" : undefined,
      hour: "numeric",
      timeZone: currentSeller.timeZone.name,
    });

  const formatRevenue = (cents: number) => {
    return new Intl.NumberFormat(userAgentInfo.locale, {
      style: "currency",
      currency: "USD",
      minimumFractionDigits: 0,
      maximumFractionDigits: 0,
    }).format(cents / 100);
  };

  const selectedCollection = selectedCollectionId ? discountCollections.find(c => c.id === selectedCollectionId) : null;

  return view === "list" ? (
    <Layout
      currentPage="discount_collections"
      pages={pages}
      actions={
        <>
          <Popover
            open={isSearchPopoverOpen}
            onToggle={setIsSearchPopoverOpen}
            aria-label="Search"
            trigger={
              <div className="button">
                <Icon name="solid-search" />
              </div>
            }
          >
            <div className="input">
              <Icon name="solid-search" />
              <input
                ref={searchInputRef}
                type="text"
                placeholder="Search"
                value={searchQuery ?? ""}
                onChange={(evt) => {
                  setSearchQuery(evt.target.value);
                  debouncedLoadDiscountCollections();
                }}
              />
            </div>
          </Popover>
          <Button
            color="accent"
            onClick={() => {
              setSelectedCollectionId(null);
              setView("create");
            }}
            disabled={false}
          >
            New collection
          </Button>
        </>
      }
    >
      <section className="paragraphs">
        {discountCollections.length > 0 ? (
          <>
            <table aria-live="polite" aria-busy={isLoading}>
              <thead>
                <tr>
                  <th {...thProps("name")}>Collection</th>
                  <th {...thProps("offer_codes_count")}>Discount Codes</th>
                  <th>Total Uses</th>
                  <th>Total Revenue</th>
                  <th {...thProps("created_at")}>Created</th>
                </tr>
              </thead>
              <tbody>
                {discountCollections.map((collection) => {
                  const createdDate = new Date(collection.created_at);

                  return (
                    <tr
                      key={collection.id}
                      aria-selected={collection.id === selectedCollectionId}
                      onClick={() => setSelectedCollectionId(collection.id)}
                    >
                      <td>
                        <div style={{ display: "grid", gap: "var(--spacer-2)" }}>
                          <div>
                            <b>{collection.name}</b>
                          </div>
                          {collection.description && (
                            <small>{collection.description}</small>
                          )}
                        </div>
                      </td>
                      <td>{collection.offer_codes_count}</td>
                      <td>{collection.total_uses}</td>
                      <td>{formatRevenue(collection.total_revenue_cents)}</td>
                      <td>{formatDateTime(createdDate)}</td>
                      <td>
                        <div className="actions">
                          <Button
                            aria-label="View collection"
                            onClick={() => {
                              window.location.href = `/checkout/discount_collections/${collection.id}`;
                            }}
                          >
                            <Icon name="arrow-right" />
                          </Button>
                          <Button
                            aria-label="Edit"
                            disabled={!collection.can_update || isLoading}
                            onClick={() => {
                              setSelectedCollectionId(collection.id);
                              setView("edit");
                            }}
                          >
                            <Icon name="pencil" />
                          </Button>
                          <Button
                            aria-label="Bulk create codes"
                            disabled={!collection.can_update || isLoading}
                            onClick={() => {
                              setSelectedCollectionId(collection.id);
                              setView("bulk_create");
                            }}
                          >
                            <Icon name="plus" />
                          </Button>
                          <Popover
                            open={popoverCollectionId === collection.id}
                            onToggle={(open) => setPopoverCollectionId(open ? collection.id : null)}
                            aria-label="Open collection action menu"
                            trigger={
                              <div className="button">
                                <Icon name="three-dots" />
                              </div>
                            }
                          >
                            <div role="menu">
                              <div
                                role="menuitem"
                                className="danger"
                                inert={!collection.can_destroy || isLoading}
                                onClick={asyncVoid(async () => {
                                  try {
                                    setIsLoading(true);
                                    await deleteCollection(collection.id);
                                  } catch (e) {
                                    assertResponseError(e);
                                    showAlert(e.message, "error");
                                  }
                                  setIsLoading(false);
                                })}
                              >
                                <Icon name="trash2" />
                                &ensp;Delete
                              </div>
                            </div>
                          </Popover>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
            {pagination.pages > 1 ? (
              <Pagination
                onChangePage={(newPage) => loadDiscountCollections({ page: newPage, query: searchQuery, sort })}
                pagination={pagination}
              />
            ) : null}
          </>
        ) : (
          <div className="placeholder">
            <figure>
              <img src={placeholder} alt="" />
            </figure>
            <div>
              <h2>No discount collections yet</h2>
              <p>Create collections to organize your discount codes and generate multiple codes at once</p>
              <p>
                <a data-helper-prompt="How can I create discount collections?">Learn more about discount collections</a>
              </p>
            </div>
          </div>
        )}
        {selectedCollection ? (
          <aside>
            <header>
              <h2>{selectedCollection.name}</h2>
              <button className="close" aria-label="Close" onClick={() => setSelectedCollectionId(null)} />
            </header>
            <section className="stack">
              <h3>Details</h3>
              {selectedCollection.description && (
                <div>
                  <h5>Description</h5>
                  <p>{selectedCollection.description}</p>
                </div>
              )}
              <div>
                <h5>Discount Codes</h5>
                {selectedCollection.offer_codes_count}
              </div>
              <div>
                <h5>Total Uses</h5>
                {selectedCollection.total_uses}
              </div>
              <div>
                <h5>Total Revenue</h5>
                {formatRevenue(selectedCollection.total_revenue_cents)}
              </div>
              <div>
                <h5>Created</h5>
                {formatDateTime(new Date(selectedCollection.created_at))}
              </div>
            </section>
            <section
              style={{ display: "grid", gap: "var(--spacer-4)", gridAutoFlow: "column", gridAutoColumns: "1fr" }}
            >
              <Button onClick={() => setView("edit")} disabled={!selectedCollection.can_update || isLoading}>
                Edit
              </Button>
              <Button onClick={() => setView("bulk_create")} disabled={!selectedCollection.can_update || isLoading}>
                Bulk Create Codes
              </Button>
              <Button
                color="danger"
                onClick={asyncVoid(async () => {
                  if (!selectedCollectionId) return;
                  await deleteCollection(selectedCollectionId);
                  setSelectedCollectionId(null);
                })}
                disabled={!selectedCollection.can_destroy || isLoading}
              >
                {isLoading ? "Deleting..." : "Delete"}
              </Button>
            </section>
          </aside>
        ) : null}
      </section>
    </Layout>
  ) : view === "edit" ? (
    <DiscountCollectionForm
      title="Edit collection"
      submitLabel={isLoading ? "Saving changes..." : "Save changes"}
      collection={selectedCollection ?? null}
      cancel={() => setView("list")}
      save={asyncVoid(async (collection) => {
        if (!selectedCollection) return;
        try {
          setIsLoading(true);
          const { discount_collections: collections, pagination: newPagination } = await updateDiscountCollection(selectedCollection.id, collection);
          setDiscountCollections(collections);
          setPagination(newPagination);
          showAlert("Successfully updated collection!", "success");
          setView("list");
        } catch (e) {
          assertResponseError(e);
          showAlert(e.message, "error");
        } finally {
          setIsLoading(false);
        }
      })}
      isLoading={isLoading}
    />
  ) : view === "bulk_create" ? (
    <BulkCreateCodesForm
      collection={selectedCollection ?? null}
      products={products as any}
      cancel={() => setView("list")}
      save={asyncVoid(async (payload: any) => {
        if (!selectedCollection) return;
        try {
          setIsLoading(true);
          const result = await bulkCreateCodes(selectedCollection.id, payload);
          showAlert(result.message, "success");
          setView("list");
        } catch (e) {
          assertResponseError(e);
          showAlert(e.message, "error");
        } finally {
          setIsLoading(false);
        }
      })}
      isLoading={isLoading}
    />
  ) : (
    <DiscountCollectionForm
      title="Create collection"
      submitLabel={isLoading ? "Creating collection..." : "Create collection"}
      cancel={() => setView("list")}
      save={asyncVoid(async (collection) => {
        try {
          setIsLoading(true);
          const { discount_collections: collections, pagination: newPagination } = await createDiscountCollection(collection);
          setDiscountCollections(collections);
          setPagination(newPagination);
          setSelectedCollectionId(collections[0]?.id ?? null);
          showAlert("Successfully created collection!", "success");
          setView("list");
        } catch (e) {
          assertResponseError(e);
          showAlert(e.message, "error");
        } finally {
          setIsLoading(false);
        }
      })}
      isLoading={isLoading}
    />
  );
};

export default register({ component: DiscountCollectionsPage, propParser: createCast() });
