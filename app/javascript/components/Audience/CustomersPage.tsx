import { Blob, DirectUpload } from "@rails/activestorage";
import cx from "classnames";
import { lightFormat, subMonths } from "date-fns";
import { format } from "date-fns-tz";
import * as React from "react";

import {
  Address,
  Call,
  Charge,
  Commission,
  Customer,
  CustomerEmail,
  Discount,
  File,
  License,
  MissedPost,
  Option,
  Query,
  Review,
  ReviewVideo,
  SortKey,
  Tracking,
  approveReviewVideo,
  cancelSubscription,
  changeCanContact,
  completeCommission,
  getCharges,
  getCustomerEmails,
  getMissedPosts,
  getOptions,
  getPagedCustomers,
  getProductPurchases,
  markShipped,
  refund,
  rejectReviewVideo,
  resendPing,
  resendPost,
  resendReceipt,
  revokeAccess,
  undoRevokeAccess,
  updateCallUrl,
  updateCommission,
  updateLicense,
  updateOption,
  updatePurchase,
} from "$app/data/customers";
import { classNames } from "$app/utils/classNames";
import {
  CurrencyCode,
  formatPriceCentsWithCurrencySymbol,
  formatPriceCentsWithoutCurrencySymbol,
} from "$app/utils/currency";
import { formatCallDate } from "$app/utils/date";
import { isValidEmail } from "$app/utils/email";
import FileUtils from "$app/utils/file";
import { asyncVoid } from "$app/utils/promise";
import { RecurrenceId, recurrenceLabels } from "$app/utils/recurringPricing";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Button, NavigationButton, buttonVariants } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { DateInput } from "$app/components/DateInput";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { FileKindIcon } from "$app/components/FileRowContent";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { NumberInput } from "$app/components/NumberInput";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { PriceInput } from "$app/components/PriceInput";
import { RatingStars } from "$app/components/RatingStars";
import { ReviewResponseForm } from "$app/components/ReviewResponseForm";
import { ReviewVideoPlayer } from "$app/components/ReviewVideoPlayer";
import { Search } from "$app/components/Search";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Switch } from "$app/components/ui/Switch";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";
import { useSortingTableDriver } from "$app/components/useSortingTableDriver";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/customers.png";

type Product = { id: string; name: string; variants: { id: string; name: string }[] };

export type CustomerPageProps = {
  customers: Customer[];
  pagination: PaginationProps | null;
  product_id: string | null;
  products: Product[];
  count: number;
  currency_type: CurrencyCode;
  countries: string[];
  can_ping: boolean;
  show_refund_fee_notice: boolean;
};

const year = new Date().getFullYear();

const formatPrice = (priceCents: number, currencyType: CurrencyCode, recurrence?: RecurrenceId | null) =>
  `${formatPriceCentsWithCurrencySymbol(currencyType, priceCents, { symbolFormat: "long" })}${
    recurrence ? ` ${recurrenceLabels[recurrence]}` : ""
  }`;

const formatDiscount = (discount: Discount, currencyType: CurrencyCode) =>
  discount.type === "fixed"
    ? formatPriceCentsWithCurrencySymbol(currencyType, discount.cents, {
        symbolFormat: "short",
      })
    : `${discount.percents}%`;

const CustomersPage = ({
  product_id,
  products,
  currency_type,
  countries,
  can_ping,
  show_refund_fee_notice,
  ...initialState
}: CustomerPageProps) => {
  const currentSeller = useCurrentSeller();
  const userAgentInfo = useUserAgentInfo();

  const [{ customers, pagination, count }, setState] = React.useState<{
    customers: Customer[];
    pagination: PaginationProps | null;
    count: number;
  }>(initialState);
  const updateCustomer = (id: string, update: Partial<Customer>) =>
    setState((prev) => ({
      ...prev,
      customers: prev.customers.map((customer) => (customer.id === id ? { ...customer, ...update } : customer)),
    }));
  const [isLoading, setIsLoading] = React.useState(false);
  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);

  const uid = React.useId();

  const [includedItems, setIncludedItems] = React.useState<Item[]>(
    product_id ? [{ type: "product", id: product_id }] : [],
  );
  const [excludedItems, setExcludedItems] = React.useState<Item[]>([]);

  const [query, setQuery] = React.useState<Query>(() => {
    const urlParams = typeof window !== "undefined" ? new URLSearchParams(window.location.search) : null;
    return {
      page: 1,
      query: urlParams?.get("query") ?? urlParams?.get("email") ?? null,
      sort: { key: "created_at", direction: "desc" },
      products: [],
      variants: [],
      excludedProducts: [],
      excludedVariants: [],
      minimumAmount: null,
      maximumAmount: null,
      createdAfter: null,
      createdBefore: null,
      country: null,
      activeCustomersOnly: false,
    };
  });
  const updateQuery = (update: Partial<Query>) => setQuery((prevQuery) => ({ ...prevQuery, ...update }));
  const {
    query: searchQuery,
    sort,
    minimumAmount,
    maximumAmount,
    createdAfter,
    createdBefore,
    country,
    activeCustomersOnly,
  } = query;

  const [selectedCustomerId, setSelectedCustomerId] = React.useState<string | null>(null);
  const selectedCustomer = customers.find(({ id }) => id === selectedCustomerId);

  const thProps = useSortingTableDriver<SortKey>(sort, (sort) => updateQuery({ sort }));

  const includedProductIds = includedItems.filter(({ type }) => type === "product").map(({ id }) => id);
  const includedVariantIds = includedItems.filter(({ type }) => type === "variant").map(({ id }) => id);

  const loadCustomers = async (page: number) => {
    activeRequest.current?.cancel();
    setIsLoading(true);
    const request = getPagedCustomers({
      ...query,
      page,
      products: includedProductIds,
      variants: includedVariantIds,
      excludedProducts: excludedItems.filter(({ type }) => type === "product").map(({ id }) => id),
      excludedVariants: excludedItems.filter(({ type }) => type === "variant").map(({ id }) => id),
    });
    activeRequest.current = request;

    try {
      setState(await request.response);
    } catch (e) {
      if (e instanceof AbortError) return;
      assertResponseError(e);
      showAlert(e.message, "error");
    }

    setIsLoading(false);
    activeRequest.current = null;
  };

  const reloadCustomers = async () => loadCustomers(1);

  const debouncedReloadCustomers = useDebouncedCallback(asyncVoid(reloadCustomers), 300);
  React.useEffect(() => {
    if (searchQuery !== null) debouncedReloadCustomers();
  }, [searchQuery]);

  useOnChange(() => {
    debouncedReloadCustomers();
  }, [query, includedItems, excludedItems]);

  const [from, setFrom] = React.useState(subMonths(new Date(), 1));
  const [to, setTo] = React.useState(new Date());
  const [exportPopoverOpen, setExportPopoverOpen] = React.useState(false);

  const exportNames = React.useMemo(
    () =>
      includedItems.length > 0
        ? includedItems
            .flatMap(({ type, id }) => {
              if (type === "product") {
                return products.find((product) => id === product.id)?.name ?? [];
              }
              const product = products.find(({ variants }) => variants.some((variant) => variant.id === id));
              const variant = product?.variants.find((variant) => variant.id === id);
              if (!product || !variant) return [];
              return `${product.name} - ${variant.name}`;
            })
            .join(", ")
        : null,
    [includedItems, products],
  );

  if (!currentSeller) return null;
  const timeZoneAbbreviation = format(new Date(), "z", { timeZone: currentSeller.timeZone.name });

  return (
    <div className="h-full">
      <PageHeader
        title="Sales"
        actions={
          <>
            <Search value={searchQuery ?? ""} onSearch={(query) => updateQuery({ query })} placeholder="Search sales" />
            <Popover>
              <PopoverAnchor>
                <WithTooltip tip="Filter">
                  <PopoverTrigger aria-label="Filter" asChild>
                    <Button>
                      <Icon name="filter" />
                    </Button>
                  </PopoverTrigger>
                </WithTooltip>
              </PopoverAnchor>
              <PopoverContent className="p-0">
                <Card className="w-140 border-none shadow-none">
                  <CardContent>
                    <ProductSelect
                      products={products.filter(
                        (product) => !excludedItems.find((excludedItem) => product.id === excludedItem.id),
                      )}
                      label="Customers who bought"
                      items={includedItems}
                      setItems={setIncludedItems}
                      className="grow basis-0"
                    />
                  </CardContent>
                  <CardContent>
                    <ProductSelect
                      products={products.filter(
                        (product) => !includedItems.find((includedItem) => product.id === includedItem.id),
                      )}
                      label="Customers who have not bought"
                      items={excludedItems}
                      setItems={setExcludedItems}
                      className="grow basis-0"
                    />
                  </CardContent>
                  <CardContent>
                    <div
                      style={{
                        display: "grid",
                        gap: "var(--spacer-4)",
                        gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                      }}
                      className="grow"
                    >
                      <fieldset>
                        <label htmlFor={`${uid}-minimum-amount`}>Paid more than</label>
                        <PriceInput
                          id={`${uid}-minimum-amount`}
                          currencyCode={currency_type}
                          cents={minimumAmount}
                          onChange={(minimumAmount) => updateQuery({ minimumAmount })}
                          placeholder="0"
                        />
                      </fieldset>
                      <fieldset>
                        <label htmlFor={`${uid}-maximum-amount`}>Paid less than</label>
                        <PriceInput
                          id={`${uid}-maximum-amount`}
                          currencyCode={currency_type}
                          cents={maximumAmount}
                          onChange={(maximumAmount) => updateQuery({ maximumAmount })}
                          placeholder="0"
                        />
                      </fieldset>
                    </div>
                  </CardContent>
                  <CardContent>
                    <div
                      style={{
                        display: "grid",
                        gap: "var(--spacer-4)",
                        gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                      }}
                      className="grow"
                    >
                      <fieldset>
                        <label htmlFor={`${uid}-after-date`}>After</label>
                        <DateInput
                          id={`${uid}-after-date`}
                          value={createdAfter}
                          onChange={(createdAfter) => updateQuery({ createdAfter })}
                          max={createdBefore || undefined}
                        />
                        <small suppressHydrationWarning>{`00:00  ${timeZoneAbbreviation}`}</small>
                      </fieldset>
                      <fieldset>
                        <label htmlFor={`${uid}-before-date`}>Before</label>
                        <DateInput
                          id={`${uid}-before-date`}
                          value={createdBefore}
                          onChange={(createdBefore) => updateQuery({ createdBefore })}
                          min={createdAfter || undefined}
                        />
                        <small suppressHydrationWarning>{`11:59 ${timeZoneAbbreviation}`}</small>
                      </fieldset>
                    </div>
                  </CardContent>
                  <CardContent>
                    <fieldset className="grow basis-0">
                      <label htmlFor={`${uid}-country`}>From</label>
                      <select
                        id={`${uid}-country`}
                        value={country ?? "Anywhere"}
                        onChange={(evt) =>
                          updateQuery({ country: evt.target.value === "Anywhere" ? null : evt.target.value })
                        }
                      >
                        <option>Anywhere</option>
                        {countries.map((country) => (
                          <option value={country} key={country}>
                            {country}
                          </option>
                        ))}
                      </select>
                    </fieldset>
                  </CardContent>
                  <CardContent>
                    <h4 className="font-bold">
                      <label htmlFor={`${uid}-active-customers-only`}>Show active customers only</label>
                    </h4>
                    <Switch
                      id={`${uid}-active-customers-only`}
                      checked={activeCustomersOnly}
                      onChange={(e) => updateQuery({ activeCustomersOnly: e.target.checked })}
                    />
                  </CardContent>
                </Card>
              </PopoverContent>
            </Popover>
            <Popover open={exportPopoverOpen} onOpenChange={setExportPopoverOpen}>
              <PopoverAnchor>
                <WithTooltip tip="Export">
                  <PopoverTrigger aria-label="Export" asChild>
                    <Button>
                      <Icon name="download" />
                    </Button>
                  </PopoverTrigger>
                </WithTooltip>
              </PopoverAnchor>
              <PopoverContent>
                <div className="flex flex-col gap-4">
                  <h3>Download sales as CSV</h3>
                  <div>
                    {exportNames
                      ? `This will download sales of '${exportNames}' as a CSV, with each purchase on its own row.`
                      : "This will download a CSV with each purchase on its own row."}
                  </div>
                  <DateRangePicker from={from} to={to} setFrom={setFrom} setTo={setTo} />
                  <NavigationButtonInertia
                    color="primary"
                    href={Routes.export_purchases_path({
                      start_time: lightFormat(from, "yyyy-MM-dd"),
                      end_time: lightFormat(to, "yyyy-MM-dd"),
                      product_ids: includedProductIds,
                      variant_ids: includedVariantIds,
                    })}
                    onSuccess={() => setExportPopoverOpen(false)}
                  >
                    Download
                  </NavigationButtonInertia>
                  {count > 2000 && (
                    <div className="mt-2 text-sm text-gray-600">
                      Exports over 2,000 rows will be processed in the background and emailed to you.
                    </div>
                  )}
                </div>
              </PopoverContent>
            </Popover>
          </>
        }
      />
      <section className="p-4 md:p-8">
        {customers.length > 0 ? (
          <section className="flex flex-col gap-4">
            <Table aria-live="polite" className={cx(isLoading && "pointer-events-none opacity-50")}>
              <TableCaption>{`All sales (${count})`}</TableCaption>
              <TableHeader>
                <TableRow>
                  <TableHead>Email</TableHead>
                  <TableHead>Name</TableHead>
                  <TableHead>Product</TableHead>
                  <TableHead {...thProps("created_at")}>Purchase Date</TableHead>
                  <TableHead {...thProps("price_cents")}>Price</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {customers.map((customer) => {
                  const price = formatPrice(
                    customer.price.cents,
                    customer.price.currency_type,
                    customer.price.recurrence,
                  );
                  const createdAt = new Date(customer.created_at);
                  return (
                    <TableRow
                      key={customer.id}
                      selected={selectedCustomerId === customer.id}
                      onClick={() => setSelectedCustomerId(customer.id)}
                    >
                      <TableCell>
                        {customer.shipping && !customer.shipping.tracking.shipped ? (
                          <WithTooltip tip="Not Shipped">
                            <Icon name="truck" style={{ marginRight: "var(--spacer-2)" }} aria-label="Not Shipped" />
                          </WithTooltip>
                        ) : null}
                        {customer.email.length <= 30 ? customer.email : `${customer.email.slice(0, 27)}...`}
                      </TableCell>
                      <TableCell>{customer.name}</TableCell>
                      <TableCell>
                        {customer.product.name}
                        {customer.subscription?.is_installment_plan ? (
                          <Pill size="small" className="ml-2">
                            Installments
                          </Pill>
                        ) : null}
                        {customer.is_bundle_purchase ? (
                          <Pill size="small" className="ml-2">
                            Bundle
                          </Pill>
                        ) : null}
                        {customer.subscription ? (
                          !customer.subscription.is_installment_plan && customer.subscription.status !== "alive" ? (
                            <Pill size="small" className="ml-2">
                              Inactive
                            </Pill>
                          ) : null
                        ) : (
                          <>
                            {customer.partially_refunded ? (
                              <Pill size="small" className="ml-2">
                                Partially refunded
                              </Pill>
                            ) : null}
                            {customer.refunded ? (
                              <Pill size="small" className="ml-2">
                                Refunded
                              </Pill>
                            ) : null}
                            {customer.chargedback ? (
                              <Pill size="small" className="ml-2">
                                Chargedback
                              </Pill>
                            ) : null}
                          </>
                        )}
                        {customer.utm_link ? (
                          <WithTooltip
                            tooltipProps={{ className: "w-80 p-0" }}
                            tip={<UtmLinkStack link={customer.utm_link} showHeader={false} />}
                          >
                            <Pill size="small" className="ml-2">
                              UTM
                            </Pill>
                          </WithTooltip>
                        ) : null}
                      </TableCell>
                      <TableCell>
                        {createdAt.toLocaleDateString(userAgentInfo.locale, {
                          day: "numeric",
                          month: "short",
                          year: createdAt.getFullYear() !== year ? "numeric" : undefined,
                          hour: "numeric",
                          minute: "numeric",
                          hour12: true,
                          timeZone: currentSeller.timeZone.name,
                        })}
                      </TableCell>
                      <TableCell>
                        {customer.transaction_url_for_seller ? (
                          <a href={customer.transaction_url_for_seller}>{price}</a>
                        ) : (
                          price
                        )}
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
            {pagination && pagination.pages > 1 ? (
              <Pagination onChangePage={asyncVoid(loadCustomers)} pagination={pagination} />
            ) : null}
          </section>
        ) : (
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            {searchQuery !== null ? (
              <h2>No sales found</h2>
            ) : (
              <>
                <h2>Manage all of your sales in one place.</h2>
                Every time a new customer purchases a product from your Gumroad, their email address and other details
                are added here.
                <div>
                  <NavigationButton color="accent" href={Routes.new_product_path()}>
                    Start selling today
                  </NavigationButton>
                </div>
                <p>
                  or{" "}
                  <a href="/help/article/268-customer-dashboard" target="_blank" rel="noreferrer">
                    learn more about the audience dashboard
                  </a>
                </p>
              </>
            )}
          </Placeholder>
        )}
        {selectedCustomer ? (
          <CustomerDrawer
            key={selectedCustomerId}
            customer={selectedCustomer}
            onChange={(update) => updateCustomer(selectedCustomer.id, update)}
            onClose={() => setSelectedCustomerId(null)}
            countries={countries}
            canPing={can_ping}
            showRefundFeeNotice={show_refund_fee_notice}
          />
        ) : null}
      </section>
    </div>
  );
};

type Item = { type: "product"; id: string } | { type: "variant"; id: string; productId: string };

const ProductSelect = ({
  label,
  products,
  items,
  setItems,
  className,
}: {
  label: string;
  products: Product[];
  items: Item[];
  setItems: (items: Item[]) => void;
  className?: string;
}) => {
  const uid = React.useId();
  return (
    <fieldset className={className}>
      <legend>
        <label htmlFor={uid}>{label}</label>
      </legend>
      <Select
        inputId={uid}
        options={products.flatMap((product) => [
          { id: product.id, label: product.name, type: "product" },
          ...product.variants.map(({ id, name }) => ({
            id: `${product.id} ${id}`,
            label: `${product.name} - ${name}`,
          })),
        ])}
        value={items.flatMap((item) => {
          if (item.type === "product") {
            const product = products.find(({ id }) => id === item.id);
            if (!product) return [];
            return { id: item.id, label: product.name };
          }
          const product = products.find(({ id }) => id === item.productId);
          if (!product) return [];
          const variant = product.variants.find((variant) => variant.id === item.id);
          if (!variant) return [];
          return { id: `${product.id} ${item.id}`, label: `${product.name} - ${variant.name}` };
        })}
        onChange={(items) =>
          setItems(
            items.map((item) => {
              const [productId, variantId] = item.id.split(" ");
              return variantId ? { type: "variant", id: variantId, productId } : { type: "product", id: item.id };
            }),
          )
        }
        isMulti
        isClearable
      />
    </fieldset>
  );
};

const MEMBERSHIP_STATUS_LABELS = {
  alive: "Active",
  cancelled: "Cancelled",
  failed_payment: "Failed payment",
  fixed_subscription_period_ended: "Ended",
  pending_cancellation: "Cancellation pending",
  pending_failure: "Failure pending",
};

const INSTALLMENT_PLAN_STATUS_LABELS = {
  alive: "In progress",
  cancelled: "Cancelled",
  failed_payment: "Payment failed",
  fixed_subscription_period_ended: "Paid in full",
  pending_cancellation: "Cancellation pending",
  pending_failure: "Failure pending",
};

const PAGE_SIZE = 10;
const CustomerDrawer = ({
  customer,
  onChange,
  onClose,
  onBack,
  countries,
  canPing,
  showRefundFeeNotice,
}: {
  customer: Customer;
  onChange: (update: Partial<Customer>) => void;
  onClose: () => void;
  onBack?: () => void;
  countries: string[];
  canPing: boolean;
  showRefundFeeNotice: boolean;
}) => {
  const userAgentInfo = useUserAgentInfo();
  const currentSeller = useCurrentSeller();

  const [loadingId, setLoadingId] = React.useState<string | null>(null);
  const [missedPosts, setMissedPosts] = React.useState<MissedPost[] | null>(null);
  const [shownMissedPosts, setShownMissedPosts] = React.useState(PAGE_SIZE);
  const [emails, setEmails] = React.useState<CustomerEmail[] | null>(null);
  const [shownEmails, setShownEmails] = React.useState(PAGE_SIZE);
  const sentEmailIds = React.useRef<Set<string>>(new Set());
  useRunOnce(() => {
    getMissedPosts(customer.id, customer.email).then(setMissedPosts, (e: unknown) => {
      assertResponseError(e);
      showAlert(e.message, "error");
    });
    getCustomerEmails(customer.id).then(setEmails, (e: unknown) => {
      assertResponseError(e);
      showAlert(e.message, "error");
    });
  });

  const onSend = async (id: string, type: "receipt" | "post") => {
    setLoadingId(id);
    try {
      await (type === "receipt" ? resendReceipt(id) : resendPost(customer.id, id));
      sentEmailIds.current.add(id);
      showAlert(type === "receipt" ? "Receipt resent" : "Email Sent", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setLoadingId(null);
  };

  const [productPurchases, setProductPurchases] = React.useState<Customer[]>([]);
  const [selectedProductPurchaseId, setSelectedProductPurchaseId] = React.useState<string | null>(null);
  const selectedProductPurchase = productPurchases.find(({ id }) => id === selectedProductPurchaseId);
  useRunOnce(() => {
    if (customer.is_bundle_purchase)
      void getProductPurchases(customer.id).then(setProductPurchases, (e: unknown) => {
        assertResponseError(e);
        showAlert(e.message, "error");
      });
  });

  const { subscription, commission, license, shipping } = customer;

  const showCharges = subscription || commission;
  const [charges, setCharges] = React.useState<Charge[]>([]);
  const [isLoadingCharges, setIsLoadingCharges] = React.useState(true);
  React.useEffect(() => {
    if (showCharges) {
      setIsLoadingCharges(true);
      getCharges(customer.id, customer.email)
        .then((charges) => {
          setCharges(charges);
        })
        .catch((e: unknown) => {
          assertResponseError(e);
          showAlert(e.message, "error");
        })
        .finally(() => {
          setIsLoadingCharges(false);
        });
    }
  }, [commission?.status]);

  const isCoffee = customer.product.native_type === "coffee";

  if (selectedProductPurchase)
    return (
      <CustomerDrawer
        customer={selectedProductPurchase}
        onChange={(update) =>
          setProductPurchases((prev) => [
            ...prev.filter(({ id }) => id !== selectedProductPurchase.id),
            { ...selectedProductPurchase, ...update },
          ])
        }
        onClose={onClose}
        onBack={() => setSelectedProductPurchaseId(null)}
        countries={countries}
        canPing={canPing}
        showRefundFeeNotice={showRefundFeeNotice}
      />
    );

  const formatDateWithoutTime = (date: Date) =>
    date.toLocaleDateString(userAgentInfo.locale, {
      day: "numeric",
      month: "short",
      year: date.getFullYear() !== year ? "numeric" : undefined,
      timeZone: currentSeller?.timeZone.name,
    });

  return (
    <Sheet open onOpenChange={onClose}>
      <SheetHeader>
        <div className="flex gap-4">
          {onBack ? (
            <button onClick={onBack} aria-label="Return to bundle" className="cursor-pointer all-unset">
              <Icon name="arrow-left" style={{ fontSize: "var(--big-icon-size)" }} />
            </button>
          ) : null}
          <h2>{customer.product.name}</h2>
        </div>
      </SheetHeader>
      {commission ? (
        <div>
          <CommissionStatusPill commission={commission} />
        </div>
      ) : null}
      {customer.is_additional_contribution ? (
        <Alert role="status" variant="info">
          <strong>Additional amount: </strong>
          This is an additional contribution, added to a previous purchase of this product.
        </Alert>
      ) : null}
      {customer.ppp ? (
        <Alert role="status" variant="info">
          This customer received a purchasing power parity discount of <b>{customer.ppp.discount}</b> because they are
          located in <b>{customer.ppp.country}</b>.
        </Alert>
      ) : null}
      {customer.giftee_email ? (
        <Alert role="status" variant="info">
          {customer.email} purchased this for {customer.giftee_email}.
        </Alert>
      ) : null}
      {customer.is_preorder ? (
        <Alert role="status" variant="info">
          <strong>Pre-order: </strong>
          This is a pre-order authorization. The customer's card has not been charged yet.
        </Alert>
      ) : null}
      {customer.affiliate && customer.affiliate.type !== "Collaborator" ? (
        <Alert role="status" variant="info">
          <strong>Affiliate: </strong>
          An affiliate ({customer.affiliate.email}) helped you make this sale and received {customer.affiliate.amount}.
        </Alert>
      ) : null}
      <EmailSection
        label="Email"
        email={customer.email}
        onSave={
          customer.is_existing_user
            ? null
            : (email) =>
                updatePurchase(customer.id, { email }).then(
                  () => {
                    showAlert("Email updated successfully.", "success");
                    onChange({ email });
                    if (productPurchases.length)
                      setProductPurchases((prevProductPurchases) =>
                        prevProductPurchases.map((productPurchase) => ({ ...productPurchase, email })),
                      );
                  },
                  (e: unknown) => {
                    assertResponseError(e);
                    showAlert(e.message, "error");
                  },
                )
        }
        canContact={customer.can_contact}
        onChangeCanContact={(canContact) =>
          changeCanContact(customer.id, canContact).then(
            () => {
              showAlert(
                canContact
                  ? "Your customer will now receive your posts."
                  : "Your customer will no longer receive your posts.",
                "success",
              );
              onChange({ can_contact: canContact });
            },
            (e: unknown) => {
              assertResponseError(e);
              showAlert(e.message, "error");
            },
          )
        }
      />
      {customer.giftee_email ? (
        <EmailSection
          label="Giftee email"
          email={customer.giftee_email}
          onSave={(email) =>
            updatePurchase(customer.id, { giftee_email: email }).then(
              () => {
                showAlert("Email updated successfully.", "success");
                onChange({ giftee_email: email });
              },
              (e: unknown) => {
                assertResponseError(e);
                showAlert(e.message, "error");
              },
            )
          }
        />
      ) : null}
      <Card asChild>
        <section>
          <CardContent asChild>
            <h3 className="flex gap-1">
              Order information
              {!subscription && customer.transaction_url_for_seller ? (
                <a
                  href={customer.transaction_url_for_seller}
                  target="_blank"
                  rel="noreferrer"
                  aria-label="Transaction"
                  className="grow"
                >
                  <Icon name="arrow-up-right-square" />
                </a>
              ) : null}
            </h3>
          </CardContent>
          <CardContent>
            <h5 className="grow font-bold">Customer name</h5>
            {customer.name}
          </CardContent>
          <CardContent>
            <h5 className="grow font-bold">{customer.is_multiseat_license ? "Seats" : "Quantity"}</h5>
            {customer.quantity}
          </CardContent>
          {customer.download_count ? (
            <CardContent>
              <h5 className="grow font-bold">Download count</h5>
              {customer.download_count}
            </CardContent>
          ) : null}
          <CardContent>
            <h5 className="grow font-bold">Price</h5>
            <div>
              {customer.price.cents_before_offer_code > customer.price.cents ? (
                <>
                  <s>
                    {formatPrice(
                      customer.price.cents_before_offer_code,
                      customer.price.currency_type,
                      customer.price.recurrence,
                    )}
                  </s>{" "}
                </>
              ) : null}
              {formatPrice(
                customer.price.cents - (customer.price.tip_cents ?? 0),
                customer.price.currency_type,
                customer.price.recurrence,
              )}
            </div>
          </CardContent>
          {customer.price.tip_cents ? (
            <CardContent>
              <h5 className="grow font-bold">Tip</h5>
              {formatPrice(customer.price.tip_cents, customer.price.currency_type, customer.price.recurrence)}
            </CardContent>
          ) : null}
          {customer.discount && !customer.upsell ? (
            <CardContent>
              <h5 className="grow font-bold">Discount</h5>
              {customer.discount.code ? (
                <div>
                  {formatDiscount(customer.discount, customer.price.currency_type)} off with code{" "}
                  <Pill size="small">{customer.discount.code.toUpperCase()}</Pill>
                </div>
              ) : (
                `${formatDiscount(customer.discount, customer.price.currency_type)} off`
              )}
            </CardContent>
          ) : null}
          {customer.upsell ? (
            <CardContent>
              <h5 className="grow font-bold">Upsell</h5>
              {`${customer.upsell}${
                customer.discount ? ` (${formatDiscount(customer.discount, customer.price.currency_type)} off)` : ""
              }`}
            </CardContent>
          ) : null}
          {subscription?.status ? (
            <CardContent>
              <h5 className="grow font-bold">
                {subscription.is_installment_plan ? "Installment plan status" : "Membership status"}
              </h5>
              <div
                style={{
                  color:
                    subscription.status === "alive" || subscription.status === "fixed_subscription_period_ended"
                      ? undefined
                      : "var(--red)",
                }}
              >
                {subscription.is_installment_plan
                  ? INSTALLMENT_PLAN_STATUS_LABELS[subscription.status]
                  : MEMBERSHIP_STATUS_LABELS[subscription.status]}
              </div>
            </CardContent>
          ) : null}
          {customer.referrer ? (
            <CardContent>
              <h5 className="grow font-bold">Referrer</h5>
              {customer.referrer}
            </CardContent>
          ) : null}
          {customer.physical ? (
            <>
              <CardContent>
                <h5 className="grow font-bold">SKU</h5>
                {customer.physical.sku}
              </CardContent>
              <CardContent>
                <h5 className="grow font-bold">Order number</h5>
                {customer.physical.order_number}
              </CardContent>
            </>
          ) : null}
        </section>
      </Card>
      {customer.utm_link ? <UtmLinkStack link={customer.utm_link} showHeader /> : null}
      {customer.review ? (
        <ReviewSection
          review={customer.review}
          purchaseId={customer.id}
          onChange={(updatedReview) => onChange({ review: updatedReview })}
        />
      ) : null}
      {customer.custom_fields.length > 0 ? (
        <Card asChild>
          <section>
            <CardContent asChild>
              <header>
                <h3 className="grow">Information provided</h3>
              </header>
            </CardContent>
            {customer.custom_fields.map((field, idx) => {
              const content = (
                <CardContent asChild>
                  <section key={idx}>
                    <h5 className="grow font-bold">{field.attribute}</h5>
                    {field.type === "text" ? (
                      field.value
                    ) : (
                      <Rows role="list" className="mt-2">
                        {field.files.map((file) => (
                          <FileRow file={file} key={file.key} />
                        ))}
                      </Rows>
                    )}
                  </section>
                </CardContent>
              );
              return field.type === "file" ? <div key={idx}>{content}</div> : content;
            })}
          </section>
        </Card>
      ) : null}
      {customer.has_options && !isCoffee && customer.product.native_type !== "call" ? (
        <OptionSection
          option={customer.option}
          onChange={(option) => onChange({ option })}
          purchaseId={customer.id}
          productPermalink={customer.product.permalink}
          isSubscription={!!subscription}
          quantity={customer.quantity}
        />
      ) : null}
      {customer.is_bundle_purchase ? (
        <Card asChild>
          <section>
            <CardContent asChild>
              <header>
                <h3 className="grow">Content</h3>
              </header>
            </CardContent>
            {productPurchases.length > 0 ? (
              productPurchases.map((customer) => (
                <CardContent asChild key={customer.id}>
                  <section>
                    <h5 className="grow font-bold">{customer.product.name}</h5>
                    <Button onClick={() => setSelectedProductPurchaseId(customer.id)}>Manage</Button>
                  </section>
                </CardContent>
              ))
            ) : (
              <CardContent asChild>
                <section>
                  <div className="grow text-center">
                    <LoadingSpinner className="size-8" />
                  </div>
                </section>
              </CardContent>
            )}
          </section>
        </Card>
      ) : null}
      {license ? (
        <LicenseSection
          license={license}
          onSave={(enabled) =>
            updateLicense(license.id, enabled).then(
              () => {
                showAlert("Changes saved!", "success");
                onChange({ license: { ...license, enabled } });
              },
              (e: unknown) => {
                assertResponseError(e);
                showAlert(e.message, "error");
              },
            )
          }
        />
      ) : null}
      {customer.is_multiseat_license ? (
        <SeatSection
          seats={customer.quantity}
          onSave={(quantity) =>
            updatePurchase(customer.id, { quantity }).then(
              () => {
                showAlert("Successfully updated seats!", "success");
                onChange({ quantity });
              },
              (e: unknown) => {
                assertResponseError(e);
                showAlert(e.message, "error");
              },
            )
          }
        />
      ) : null}
      {shipping ? (
        <>
          <TrackingSection
            tracking={shipping.tracking}
            onMarkShipped={(url) =>
              markShipped(customer.id, url).then(
                () => {
                  showAlert("Changes saved!", "success");
                  onChange({ shipping: { ...shipping, tracking: { url, shipped: true } } });
                },
                (e: unknown) => {
                  assertResponseError(e);
                  showAlert(e.message, "error");
                },
              )
            }
          />
          <AddressSection
            address={shipping.address}
            price={shipping.price}
            onSave={(address) =>
              updatePurchase(customer.id, address).then(
                () => {
                  showAlert("Changes saved!", "success");
                  onChange({ shipping: { ...shipping, address } });
                },
                (e: unknown) => {
                  assertResponseError(e);
                  showAlert(e.message, "error");
                },
              )
            }
            countries={countries}
          />
        </>
      ) : null}
      {customer.call ? <CallSection call={customer.call} onChange={(call) => onChange({ ...customer, call })} /> : null}
      {!showCharges && !customer.refunded && !customer.chargedback && customer.price.cents_refundable > 0 ? (
        <Card asChild>
          <section>
            <CardContent asChild>
              <header>
                <h3 className="grow">Refund</h3>
              </header>
            </CardContent>
            <CardContent asChild>
              <section>
                <RefundForm
                  purchaseId={customer.id}
                  currencyType={customer.price.currency_type}
                  amountRefundable={customer.price.cents_refundable}
                  showRefundFeeNotice={showRefundFeeNotice}
                  paypalRefundExpired={customer.paypal_refund_expired}
                  modalTitle="Purchase refund"
                  modalText="Would you like to confirm this purchase refund?"
                  onChange={(amountRefundable) =>
                    onChange({
                      price: { ...customer.price, cents_refundable: amountRefundable },
                      refunded: amountRefundable === 0,
                      partially_refunded: amountRefundable > 0 && amountRefundable < customer.price.cents_refundable,
                    })
                  }
                  className="grow basis-0"
                />
              </section>
            </CardContent>
          </section>
        </Card>
      ) : null}
      {subscription?.status === "alive" ? (
        <SubscriptionCancellationSection
          isInstallmentPlan={subscription.is_installment_plan}
          onCancel={() =>
            void cancelSubscription(subscription.id).then(
              () => {
                showAlert("Changes saved!", "success");
                onChange({ subscription: { ...subscription, status: "pending_cancellation" } });
              },
              (e: unknown) => {
                assertResponseError(e);
                showAlert(e.message, "error");
              },
            )
          }
        />
      ) : null}
      {canPing && !subscription ? (
        <Card asChild>
          <section>
            <CardContent>
              <PingButton purchaseId={customer.id} className="grow basis-0" />
            </CardContent>
          </section>
        </Card>
      ) : null}
      {customer.is_access_revoked !== null && !isCoffee && !commission ? (
        <AccessSection
          purchaseId={customer.id}
          onChange={(isAccessRevoked) => onChange({ is_access_revoked: isAccessRevoked })}
          isAccessRevoked={customer.is_access_revoked}
        />
      ) : null}
      {showCharges ? (
        <ChargesSection
          charges={charges}
          remainingCharges={subscription?.remaining_charges ?? null}
          onChange={setCharges}
          showRefundFeeNotice={showRefundFeeNotice}
          canPing={canPing}
          customerEmail={customer.email}
          loading={isLoadingCharges}
        />
      ) : null}
      {commission ? (
        <CommissionSection commission={commission} onChange={(commission) => onChange({ commission })} />
      ) : null}
      {missedPosts?.length !== 0 ? (
        <Card asChild>
          <section>
            <CardContent asChild>
              <header>
                <h3 className="grow">Send missed posts</h3>
              </header>
            </CardContent>
            {missedPosts ? (
              <>
                {missedPosts.slice(0, shownMissedPosts).map((post) => (
                  <CardContent asChild key={post.id}>
                    <section>
                      <div className="grow">
                        <h5 className="font-bold">
                          <a href={post.url} target="_blank" rel="noreferrer">
                            {post.name}
                          </a>
                        </h5>
                        <small>{`Originally sent on ${formatDateWithoutTime(new Date(post.published_at))}`}</small>
                      </div>
                      <Button
                        color="primary"
                        disabled={!!loadingId || sentEmailIds.current.has(post.id)}
                        onClick={() => void onSend(post.id, "post")}
                      >
                        {sentEmailIds.current.has(post.id) ? "Sent" : loadingId === post.id ? "Sending...." : "Send"}
                      </Button>
                    </section>
                  </CardContent>
                ))}
                {shownMissedPosts < missedPosts.length ? (
                  <CardContent asChild>
                    <section>
                      <Button
                        onClick={() => setShownMissedPosts((prevShownMissedPosts) => prevShownMissedPosts + PAGE_SIZE)}
                        className="grow basis-0"
                      >
                        Show more
                      </Button>
                    </section>
                  </CardContent>
                ) : null}
              </>
            ) : (
              <CardContent asChild>
                <section>
                  <div className="grow text-center">
                    <LoadingSpinner className="size-8" />
                  </div>
                </section>
              </CardContent>
            )}
          </section>
        </Card>
      ) : null}
      {emails?.length !== 0 ? (
        <Card asChild>
          <section>
            <CardContent asChild>
              <header>
                <h3 className="grow">Emails received</h3>
              </header>
            </CardContent>
            {emails ? (
              <>
                {emails.slice(0, shownEmails).map((email) => (
                  <CardContent asChild key={email.id}>
                    <section>
                      <div className="grow">
                        <h5>
                          {email.type === "receipt" ? (
                            <a href={email.url} target="_blank" rel="noreferrer">
                              {email.name}
                            </a>
                          ) : (
                            email.name
                          )}
                        </h5>
                        <small>{`${email.state} ${formatDateWithoutTime(new Date(email.state_at))}`}</small>
                      </div>
                      {email.type === "receipt" ? (
                        <Button
                          color="primary"
                          onClick={() => void onSend(email.id, "receipt")}
                          disabled={!!loadingId || sentEmailIds.current.has(email.id)}
                        >
                          {sentEmailIds.current.has(email.id)
                            ? "Receipt resent"
                            : loadingId === email.id
                              ? "Resending receipt..."
                              : "Resend receipt"}
                        </Button>
                      ) : (
                        <Button
                          color="primary"
                          onClick={() => void onSend(email.id, "post")}
                          disabled={!!loadingId || sentEmailIds.current.has(email.id)}
                        >
                          {sentEmailIds.current.has(email.id)
                            ? "Sent"
                            : loadingId === email.id
                              ? "Sending..."
                              : "Resend email"}
                        </Button>
                      )}
                    </section>
                  </CardContent>
                ))}
                {shownMissedPosts < emails.length ? (
                  <CardContent asChild>
                    <section>
                      <Button
                        onClick={() => setShownEmails((prevShownEmails) => prevShownEmails + PAGE_SIZE)}
                        className="grow basis-0"
                      >
                        Load more
                      </Button>
                    </section>
                  </CardContent>
                ) : null}
              </>
            ) : (
              <CardContent>
                <section>
                  <div className="grow text-center">
                    <LoadingSpinner className="size-8" />
                  </div>
                </section>
              </CardContent>
            )}
          </section>
        </Card>
      ) : null}
    </Sheet>
  );
};

const CommissionStatusPill = ({ commission }: { commission: Commission }) => (
  <Pill
    size="small"
    color={commission.status === "completed" ? "primary" : commission.status === "cancelled" ? "danger" : undefined}
  >
    {commission.status === "in_progress"
      ? "In progress"
      : commission.status === "completed"
        ? "Completed"
        : "Cancelled"}
  </Pill>
);

const AddressSection = ({
  address: currentAddress,
  price,
  onSave,
  countries,
}: {
  address: Address;
  price: string;
  onSave: (address: Address) => Promise<void>;
  countries: string[];
}) => {
  const uid = React.useId();

  const [address, setAddress] = React.useState(currentAddress);
  const updateShipping = (update: Partial<Address>) => setAddress((prev) => ({ ...prev, ...update }));

  const [isEditing, setIsEditing] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSave = async () => {
    setIsLoading(true);
    await onSave(address);
    setIsLoading(false);
    setIsEditing(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">Shipping address</h3>
          </header>
        </CardContent>
        {isEditing ? (
          <CardContent>
            <div className="flex grow flex-col gap-4">
              <fieldset>
                <legend>
                  <label htmlFor={`${uid}-full-name`}>Full name</label>
                </legend>
                <input
                  id={`${uid}-full-name`}
                  type="text"
                  placeholder="Full name"
                  value={address.full_name}
                  onChange={(evt) => updateShipping({ full_name: evt.target.value })}
                />
              </fieldset>
              <fieldset>
                <legend>
                  <label htmlFor={`${uid}-street-address`}>Street address</label>
                </legend>
                <input
                  id={`${uid}-street-address`}
                  type="text"
                  placeholder="Street address"
                  value={address.street_address}
                  onChange={(evt) => updateShipping({ street_address: evt.target.value })}
                />
              </fieldset>
              <div style={{ display: "grid", gridAutoFlow: "column", gridAutoColumns: "1fr", gap: "var(--spacer-2)" }}>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-city`}>City</label>
                  </legend>
                  <input
                    id={`${uid}-city`}
                    type="text"
                    placeholder="City"
                    value={address.city}
                    onChange={(evt) => updateShipping({ city: evt.target.value })}
                  />
                </fieldset>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-state`}>State</label>
                  </legend>
                  <input
                    id={`${uid}-state`}
                    type="text"
                    placeholder="State"
                    value={address.state}
                    onChange={(evt) => updateShipping({ state: evt.target.value })}
                  />
                </fieldset>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-zip-code`}>ZIP code</label>
                  </legend>
                  <input
                    id={`${uid}-zip-code`}
                    type="text"
                    placeholder="ZIP code"
                    value={address.zip_code}
                    onChange={(evt) => updateShipping({ zip_code: evt.target.value })}
                  />
                </fieldset>
              </div>
              <fieldset>
                <label htmlFor={`${uid}-country`}>Country</label>
                <select
                  id={`${uid}-country`}
                  value={address.country}
                  onChange={(evt) => updateShipping({ country: evt.target.value })}
                >
                  {countries.map((country) => (
                    <option value={country} key={country}>
                      {country}
                    </option>
                  ))}
                </select>
              </fieldset>
              <div
                style={{
                  width: "100%",
                  display: "grid",
                  gap: "var(--spacer-2)",
                  gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                }}
              >
                <Button onClick={() => setIsEditing(false)} disabled={isLoading}>
                  Cancel
                </Button>
                <Button color="primary" onClick={() => void handleSave()} disabled={isLoading}>
                  Save
                </Button>
              </div>
            </div>
          </CardContent>
        ) : (
          <CardContent>
            <p className="grow">
              {currentAddress.full_name}
              <br />
              {currentAddress.street_address}
              <br />
              {`${currentAddress.city}, ${currentAddress.state} ${currentAddress.zip_code}`}
              <br />
              {currentAddress.country}
            </p>
            <button className="cursor-pointer underline all-unset" onClick={() => setIsEditing(true)}>
              Edit
            </button>
          </CardContent>
        )}
        <CardContent>
          <h5 className="grow font-bold">Shipping charged</h5>
          {price}
        </CardContent>
      </section>
    </Card>
  );
};

const TrackingSection = ({
  tracking,
  onMarkShipped,
}: {
  tracking: Tracking;
  onMarkShipped: (url: string) => Promise<void>;
}) => {
  const [url, setUrl] = React.useState((tracking.shipped ? tracking.url : "") ?? "");
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSave = async () => {
    setIsLoading(true);
    await onMarkShipped(url);
    setIsLoading(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <h3>Tracking information</h3>
        </CardContent>
        {tracking.shipped ? (
          tracking.url ? (
            <CardContent>
              <NavigationButton color="primary" href={tracking.url} target="_blank" className="grow">
                Track shipment
              </NavigationButton>
            </CardContent>
          ) : (
            <CardContent>
              <Alert role="status" variant="success" className="grow">
                Shipped
              </Alert>
            </CardContent>
          )
        ) : (
          <CardContent>
            <fieldset className="grow basis-0">
              <input
                type="text"
                placeholder="Tracking URL (optional)"
                value={url}
                onChange={(evt) => setUrl(evt.target.value)}
              />
              <Button color="primary" disabled={isLoading} onClick={() => void handleSave()}>
                Mark as shipped
              </Button>
            </fieldset>
          </CardContent>
        )}
      </section>
    </Card>
  );
};

const EmailSection = ({
  label,
  email: currentEmail,
  onSave,
  canContact,
  onChangeCanContact,
}: {
  label: string;
  email: string;
  onSave: ((email: string) => Promise<void>) | null;
  canContact?: boolean;
  onChangeCanContact?: (canContact: boolean) => Promise<void>;
}) => {
  const [email, setEmail] = React.useState(currentEmail);
  const [isEditing, setIsEditing] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSave = async () => {
    if (!onSave) return;

    const emailError =
      email.length === 0 ? "Email must be provided" : !isValidEmail(email) ? "Please enter a valid email" : null;

    if (emailError) {
      showAlert(emailError, "error");
      return;
    }

    setIsLoading(true);
    await onSave(email);
    setIsLoading(false);
    setIsEditing(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">{label}</h3>
          </header>
        </CardContent>
        {isEditing ? (
          <CardContent asChild>
            <fieldset>
              <input
                type="text"
                value={email}
                onChange={(evt) => setEmail(evt.target.value)}
                disabled={isLoading}
                placeholder={label}
                className="grow"
              />
              <div
                style={{
                  width: "100%",
                  display: "grid",
                  gap: "var(--spacer-2)",
                  gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                }}
              >
                <Button onClick={() => setIsEditing(false)} disabled={isLoading}>
                  Cancel
                </Button>
                <Button color="primary" onClick={() => void handleSave()} disabled={isLoading}>
                  Save
                </Button>
              </div>
            </fieldset>
          </CardContent>
        ) : (
          <CardContent asChild>
            <section>
              <h5 className="grow font-bold">{currentEmail}</h5>
              {onSave ? (
                <button className="cursor-pointer underline all-unset" onClick={() => setIsEditing(true)}>
                  Edit
                </button>
              ) : (
                <small>
                  You cannot change the email of this purchase, because it was made by an existing user. Please ask them
                  to go to gumroad.com/settings to update their email.
                </small>
              )}
            </section>
          </CardContent>
        )}
        {onChangeCanContact ? (
          <CardContent asChild>
            <section>
              <fieldset role="group" className="grow basis-0">
                <label>
                  Receives emails
                  <input
                    type="checkbox"
                    checked={canContact}
                    onChange={(evt) => {
                      setIsLoading(true);
                      void onChangeCanContact(evt.target.checked).then(() => setIsLoading(false));
                    }}
                    disabled={isLoading}
                  />
                </label>
              </fieldset>
            </section>
          </CardContent>
        ) : null}
      </section>
    </Card>
  );
};

const ReviewVideosSubsections = ({
  review,
  onChange,
  className,
}: {
  review: Review;
  className?: string;
  onChange: (review: Review) => void;
}) => {
  const [loading, setLoading] = React.useState(false);
  const [approvedVideoRemovalModalOpen, setApprovedVideoRemovalModalOpen] = React.useState(false);

  const approvedVideo = review.videos.find((video) => video.approval_status === "approved");
  const pendingVideo = review.videos.find((video) => video.approval_status === "pending_review");

  const approveVideo = async (video: ReviewVideo) => {
    setLoading(true);

    try {
      await approveReviewVideo(video.id);
      onChange({ ...review, videos: [{ ...video, approval_status: "approved" }] });
      showAlert("This video is now live!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong", "error");
    } finally {
      setLoading(false);
    }
  };

  const rejectVideo = async (video: ReviewVideo) => {
    setLoading(true);
    try {
      await rejectReviewVideo(video.id);
      const otherVideos = review.videos.filter((v) => v.id !== video.id);
      onChange({ ...review, videos: [{ ...video, approval_status: "rejected" }, ...otherVideos] });
      showAlert("This video has been removed.", "success");
      setApprovedVideoRemovalModalOpen(false);
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong", "error");
    } finally {
      setLoading(false);
    }
  };

  const approvedVideoSubsection = approvedVideo ? (
    <section className={className}>
      <div className="flex flex-col gap-4">
        <h5>Approved video</h5>
        <ReviewVideoPlayer videoId={approvedVideo.id} thumbnail={approvedVideo.thumbnail_url} />
        <Button onClick={() => setApprovedVideoRemovalModalOpen(true)} disabled={loading}>
          Remove
        </Button>
        <Modal
          open={approvedVideoRemovalModalOpen}
          onClose={() => setApprovedVideoRemovalModalOpen(false)}
          title="Remove approved video?"
          footer={
            <>
              <Button onClick={() => setApprovedVideoRemovalModalOpen(false)} disabled={loading}>
                Cancel
              </Button>
              <Button color="danger" onClick={() => void rejectVideo(approvedVideo)} disabled={loading}>
                Remove video
              </Button>
            </>
          }
        >
          <p>This action cannot be undone. This video will be permanently removed from this review.</p>
        </Modal>
      </div>
    </section>
  ) : null;

  const pendingVideoSubsection = pendingVideo ? (
    <section>
      <div className="flex flex-col gap-4">
        <h5>Pending video</h5>
        <ReviewVideoPlayer videoId={pendingVideo.id} thumbnail={pendingVideo.thumbnail_url} />
        <div className="flex flex-row gap-2">
          {pendingVideo.can_approve ? (
            <Button
              color="primary"
              className="flex-1"
              onClick={() => void approveVideo(pendingVideo)}
              disabled={loading}
            >
              Approve
            </Button>
          ) : null}
          {pendingVideo.can_reject ? (
            <Button color="danger" className="flex-1" onClick={() => void rejectVideo(pendingVideo)} disabled={loading}>
              Reject
            </Button>
          ) : null}
        </div>
      </div>
    </section>
  ) : null;

  return approvedVideoSubsection || pendingVideoSubsection ? (
    <>
      {approvedVideoSubsection}
      {pendingVideoSubsection}
    </>
  ) : null;
};

const ReviewSection = ({
  review,
  purchaseId,
  onChange,
}: {
  review: Review;
  purchaseId: string;
  onChange: (review: Review) => void;
}) => (
  <Card asChild>
    <section>
      <CardContent asChild>
        <h3>Review</h3>
      </CardContent>
      <CardContent asChild>
        <section>
          <h5 className="grow font-bold">Rating</h5>
          <div aria-label={`${review.rating} ${review.rating === 1 ? "star" : "stars"}`}>
            <RatingStars rating={review.rating} />
          </div>
        </section>
      </CardContent>
      {review.message ? (
        <CardContent asChild>
          <section>
            <h5 className="grow font-bold">Message</h5>
            {review.message}
          </section>
        </CardContent>
      ) : null}
      <CardContent asChild>
        <ReviewVideosSubsections review={review} onChange={onChange} className="grow" />
      </CardContent>
      {review.response ? (
        <CardContent asChild>
          <section>
            <h5 className="grow font-bold">Response</h5>
            {review.response.message}
          </section>
        </CardContent>
      ) : null}
      <CardContent asChild>
        <ReviewResponseForm
          message={review.response?.message}
          purchaseId={purchaseId}
          onChange={(response) => onChange({ ...review, response })}
        />
      </CardContent>
    </section>
  </Card>
);

const OptionSection = ({
  option,
  onChange,
  purchaseId,
  productPermalink,
  isSubscription,
  quantity,
}: {
  option: Option | null;
  onChange: (option: Option) => void;
  purchaseId: string;
  productPermalink: string;
  isSubscription: boolean;
  quantity: number;
}) => {
  const [options, setOptions] = React.useState<Option[]>([]);
  const [selectedOptionId, setSelectedOptionId] = React.useState<{ value: string | null; error?: boolean }>({
    value: option?.id ?? null,
  });
  const [isEditing, setIsEditing] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);

  useRunOnce(
    () =>
      void getOptions(productPermalink).then(
        (options) => setOptions(option && !options.some(({ id }) => id === option.id) ? [option, ...options] : options),
        (e: unknown) => {
          assertResponseError(e);
          showAlert(e.message, "error");
        },
      ),
  );

  const handleSave = async () => {
    const option = options.find(({ id }) => id === selectedOptionId.value);
    if (!option) return setSelectedOptionId((prev) => ({ ...prev, error: true }));
    try {
      setIsLoading(true);
      await updateOption(purchaseId, option.id, quantity);
      showAlert("Saved variant", "success");
      onChange(option);
      setIsEditing(false);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };

  const title = isSubscription ? "Tier" : "Version";

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">{title}</h3>
          </header>
        </CardContent>
        <CardContent asChild>
          <section>
            {options.length > 0 ? (
              isEditing ? (
                <fieldset className={classNames({ danger: selectedOptionId.error }, "grow basis-0")}>
                  <select
                    value={selectedOptionId.value ?? "None selected"}
                    name={title}
                    onChange={(evt) => setSelectedOptionId({ value: evt.target.value })}
                    aria-invalid={selectedOptionId.error}
                  >
                    {!selectedOptionId.value ? <option>None selected</option> : null}
                    {options.map((option) => (
                      <option value={option.id} key={option.id}>
                        {option.name}
                      </option>
                    ))}
                  </select>
                  <div
                    style={{
                      width: "100%",
                      display: "grid",
                      gap: "var(--spacer-2)",
                      gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                    }}
                  >
                    <Button onClick={() => setIsEditing(false)} disabled={isLoading}>
                      Cancel
                    </Button>
                    <Button color="primary" onClick={() => void handleSave()} disabled={isLoading}>
                      Save
                    </Button>
                  </div>
                </fieldset>
              ) : (
                <>
                  <h5>{option?.name ?? "None selected"}</h5>
                  <button className="cursor-pointer underline all-unset" onClick={() => setIsEditing(true)}>
                    Edit
                  </button>
                </>
              )
            ) : (
              <div className="grow text-center">
                <LoadingSpinner className="size-8" />
              </div>
            )}
          </section>
        </CardContent>
      </section>
    </Card>
  );
};

const UtmLinkStack = ({ link, showHeader }: { link: Customer["utm_link"]; showHeader: boolean }) => {
  if (!link) return null;

  return (
    <Card asChild>
      <section>
        {showHeader ? (
          <>
            <CardContent asChild>
              <section>
                <h3 className="grow">UTM link</h3>
              </section>
            </CardContent>
            <CardContent>
              <Alert className="grow text-sm" role="status" variant="info">
                This sale was driven by a{" "}
                <a href={link.utm_url} target="_blank" rel="noreferrer">
                  UTM link
                </a>
                .
              </Alert>
            </CardContent>
          </>
        ) : null}
        <CardContent>
          <h5 className="grow font-bold">Title</h5>
          <a href={Routes.dashboard_utm_links_path({ query: link.title })} target="_blank" rel="noreferrer">
            {link.title}
          </a>
        </CardContent>
        <CardContent>
          <h5 className="grow font-bold">Source</h5>
          {link.source}
        </CardContent>
        <CardContent>
          <h5 className="grow font-bold">Medium</h5>
          {link.medium}
        </CardContent>
        <CardContent>
          <h5 className="grow font-bold">Campaign</h5>
          {link.campaign}
        </CardContent>
        {link.term ? (
          <CardContent>
            <h5 className="grow font-bold">Term</h5>
            {link.term}
          </CardContent>
        ) : null}
        {link.content ? (
          <CardContent>
            <h5 className="grow font-bold">Content</h5>
            {link.content}
          </CardContent>
        ) : null}
      </section>
    </Card>
  );
};

const LicenseSection = ({ license, onSave }: { license: License; onSave: (enabled: boolean) => Promise<void> }) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSave = async (enabled: boolean) => {
    setIsLoading(true);
    await onSave(enabled);
    setIsLoading(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">License key</h3>
          </header>
        </CardContent>
        <CardContent>
          <pre className="grow">
            <code>{license.key}</code>
          </pre>
        </CardContent>
        <CardContent>
          {license.enabled ? (
            <Button color="danger" disabled={isLoading} onClick={() => void handleSave(false)} className="grow basis-0">
              Disable
            </Button>
          ) : (
            <Button disabled={isLoading} onClick={() => void handleSave(true)} className="grow basis-0">
              Enable
            </Button>
          )}
        </CardContent>
      </section>
    </Card>
  );
};

const SeatSection = ({ seats: currentSeats, onSave }: { seats: number; onSave: (seats: number) => Promise<void> }) => {
  const [seats, setSeats] = React.useState(currentSeats);
  const [isEditing, setIsEditing] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSave = async () => {
    setIsLoading(true);
    await onSave(seats);
    setIsLoading(false);
    setIsEditing(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">Seats</h3>
          </header>
        </CardContent>
        {isEditing ? (
          <CardContent asChild>
            <fieldset>
              <NumberInput value={seats} onChange={(seats) => setSeats(seats ?? 0)}>
                {(props) => <input type="number" {...props} min={1} aria-label="Seats" className="grow" />}
              </NumberInput>
              <div
                style={{
                  width: "100%",
                  display: "grid",
                  gap: "var(--spacer-2)",
                  gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                }}
              >
                <Button onClick={() => setIsEditing(false)} disabled={isLoading}>
                  Cancel
                </Button>
                <Button color="primary" onClick={() => void handleSave()} disabled={isLoading}>
                  Save
                </Button>
              </div>
            </fieldset>
          </CardContent>
        ) : (
          <CardContent asChild>
            <section>
              <h5 className="grow font-bold">{seats}</h5>
              <button className="cursor-pointer underline all-unset" onClick={() => setIsEditing(true)}>
                Edit
              </button>
            </section>
          </CardContent>
        )}
      </section>
    </Card>
  );
};

const SubscriptionCancellationSection = ({
  onCancel,
  isInstallmentPlan,
}: {
  onCancel: () => void;
  isInstallmentPlan: boolean;
}) => {
  const [open, setOpen] = React.useState(false);
  const constructor = isInstallmentPlan ? "installment plan" : "subscription";
  return (
    <Card asChild>
      <section>
        <CardContent>
          <Button color="danger" onClick={() => setOpen(true)} className="grow basis-0">
            Cancel {constructor}
          </Button>
          <Modal
            open={open}
            title={`Cancel ${constructor}`}
            onClose={() => setOpen(false)}
            footer={
              <>
                <Button onClick={() => setOpen(false)}>Cancel</Button>
                <Button color="accent" onClick={onCancel}>
                  Cancel {constructor}
                </Button>
              </>
            }
          >
            Would you like to cancel this {constructor}?
          </Modal>
        </CardContent>
      </section>
    </Card>
  );
};

const PingButton = ({ purchaseId, className }: { purchaseId: string; className?: string }) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const handleClick = async () => {
    setIsLoading(true);
    try {
      await resendPing(purchaseId);
      showAlert("Ping resent.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Button color="primary" disabled={isLoading} onClick={() => void handleClick()} className={className}>
      {isLoading ? "Resending ping..." : "Resend ping"}
    </Button>
  );
};

const AccessSection = ({
  purchaseId,
  isAccessRevoked,
  onChange,
}: {
  purchaseId: string;
  isAccessRevoked: boolean;
  onChange: (accessRevoked: boolean) => void;
}) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const handleClick = async (revoke: boolean) => {
    setIsLoading(true);
    try {
      if (revoke) {
        await revokeAccess(purchaseId);
        showAlert("Access revoked", "success");
        onChange(true);
      } else {
        await undoRevokeAccess(purchaseId);
        showAlert("Access re-enabled", "success");
        onChange(false);
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent>
          {isAccessRevoked ? (
            <Button disabled={isLoading} onClick={() => void handleClick(false)} className="grow basis-0">
              Re-enable access
            </Button>
          ) : (
            <Button
              color="primary"
              disabled={isLoading}
              onClick={() => void handleClick(true)}
              className="grow basis-0"
            >
              Revoke access
            </Button>
          )}
        </CardContent>
      </section>
    </Card>
  );
};

const RefundForm = ({
  purchaseId,
  currencyType,
  amountRefundable,
  showRefundFeeNotice,
  paypalRefundExpired,
  modalTitle,
  modalText,
  onChange,
  onClose,
  className,
}: {
  purchaseId: string;
  currencyType: CurrencyCode;
  amountRefundable: number;
  showRefundFeeNotice: boolean;
  paypalRefundExpired: boolean;
  modalTitle: string;
  modalText: string;
  onChange: (amountRefundable: number) => void;
  onClose?: () => void;
  className?: string;
}) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const [isModalShowing, setIsModalShowing] = React.useState(false);
  const [refundAmountCents, setRefundAmountCents] = React.useState<{ value: number | null; error?: boolean }>({
    value: amountRefundable,
  });

  const refundAmountRemaining = amountRefundable - (refundAmountCents.value ?? 0);
  const isPartialRefund = refundAmountRemaining > 0;

  const handleRefund = async () => {
    if (!refundAmountCents.value) {
      setIsModalShowing(false);
      return setRefundAmountCents((prev) => ({ ...prev, error: true }));
    }
    try {
      setIsLoading(true);
      await refund(purchaseId, refundAmountCents.value / 100.0);
      const refundAmountRemaining = amountRefundable - refundAmountCents.value;
      onChange(refundAmountRemaining);
      setRefundAmountCents({ value: refundAmountRemaining });
      showAlert("Purchase successfully refunded.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
    setIsModalShowing(false);
  };

  const refundButton = (
    <Button color="primary" onClick={() => setIsModalShowing(true)} disabled={isLoading || paypalRefundExpired}>
      {isLoading ? "Refunding..." : isPartialRefund ? "Issue partial refund" : "Refund fully"}
    </Button>
  );

  return (
    <>
      <fieldset className={classNames({ danger: refundAmountCents.error }, className)}>
        <PriceInput
          cents={refundAmountCents.value}
          onChange={(value) => setRefundAmountCents({ value })}
          currencyCode={currencyType}
          placeholder={formatPriceCentsWithoutCurrencySymbol(currencyType, amountRefundable)}
          hasError={refundAmountCents.error ?? false}
        />
        <div
          style={{
            width: "100%",
            display: "grid",
            gap: "var(--spacer-2)",
            gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
          }}
        >
          {onClose ? (
            <Button onClick={onClose} disabled={isLoading}>
              Cancel
            </Button>
          ) : null}
          {paypalRefundExpired ? (
            <WithTooltip tip="PayPal refunds aren't available after 6 months." position="top">
              {refundButton}
            </WithTooltip>
          ) : (
            refundButton
          )}
        </div>
        {showRefundFeeNotice ? (
          <Alert role="status" variant="info">
            Going forward, Gumroad does not return any fees when a payment is refunded.{" "}
            <a href="/help/article/47-how-to-refund-a-customer" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </Alert>
        ) : null}
      </fieldset>
      <div style={{ display: "contents" }}>
        <Modal
          usePortal
          open={isModalShowing}
          onClose={() => setIsModalShowing(false)}
          title={modalTitle}
          footer={
            <>
              <Button onClick={() => setIsModalShowing(false)} disabled={isLoading}>
                Cancel
              </Button>
              <Button color="accent" onClick={() => void handleRefund()} disabled={isLoading}>
                {isLoading ? "Refunding..." : "Confirm refund"}
              </Button>
            </>
          }
        >
          {modalText}
        </Modal>
      </div>
    </>
  );
};

const ChargeRow = ({
  purchase,
  customerEmail,
  onChange,
  showRefundFeeNotice,
  canPing,
  className,
}: {
  purchase: Charge;
  customerEmail: string;
  onChange: (update: Partial<Charge>) => void;
  showRefundFeeNotice: boolean;
  canPing: boolean;
  className?: string;
}) => {
  const [isRefunding, setIsRefunding] = React.useState(false);
  const userAgentInfo = useUserAgentInfo();
  const currentSeller = useCurrentSeller();

  return (
    <section className={className}>
      <div className="grow">
        <section style={{ display: "flex", gap: "var(--spacer-1)", alignItems: "center" }}>
          <h5>
            {formatPrice(purchase.amount_refundable, purchase.currency_type)} on{" "}
            {new Date(purchase.created_at).toLocaleDateString(userAgentInfo.locale, {
              year: "numeric",
              month: "numeric",
              day: "numeric",
              timeZone: currentSeller?.timeZone.name,
            })}
          </h5>

          <a
            href={
              purchase.transaction_url_for_seller ?? Routes.receipt_purchase_path(purchase.id, { email: customerEmail })
            }
            target="_blank"
            rel="noreferrer"
            aria-label="Transaction"
          >
            <Icon name="arrow-up-right-square" />
          </a>
          {purchase.partially_refunded ? (
            <Pill size="small">Partial refund</Pill>
          ) : purchase.refunded ? (
            <Pill size="small">Refunded</Pill>
          ) : null}
          {purchase.is_upgrade_purchase ? (
            <WithTooltip tip="This is an upgrade charge, generated when the subscriber upgraded to a more expensive plan.">
              <Pill size="small">Upgrade</Pill>
            </WithTooltip>
          ) : null}
          {purchase.chargedback ? <Pill size="small">Chargedback</Pill> : null}
        </section>
        {!purchase.refunded && !purchase.chargedback && purchase.amount_refundable > 0 ? (
          <button className="cursor-pointer underline all-unset" onClick={() => setIsRefunding((prev) => !prev)}>
            Refund Options
          </button>
        ) : null}
      </div>
      {canPing ? <PingButton purchaseId={purchase.id} /> : null}
      {isRefunding ? (
        <RefundForm
          purchaseId={purchase.id}
          currencyType={purchase.currency_type}
          amountRefundable={purchase.amount_refundable}
          showRefundFeeNotice={showRefundFeeNotice}
          paypalRefundExpired={purchase.paypal_refund_expired}
          modalTitle="Charge refund"
          modalText="Would you like to confirm this charge refund?"
          onChange={(amountRefundable) => {
            onChange({
              amount_refundable: amountRefundable,
              refunded: amountRefundable === 0,
              partially_refunded: amountRefundable > 0 && amountRefundable < purchase.amount_refundable,
            });
            setIsRefunding(false);
          }}
          onClose={() => setIsRefunding(false)}
        />
      ) : null}
    </section>
  );
};

const ChargesSection = ({
  charges,
  remainingCharges,
  onChange,
  showRefundFeeNotice,
  canPing,
  customerEmail,
  loading,
}: {
  charges: Charge[];
  remainingCharges: number | null;
  onChange: (charges: Charge[]) => void;
  showRefundFeeNotice: boolean;
  canPing: boolean;
  customerEmail: string;
  loading: boolean;
}) => {
  const updateCharge = (id: string, update: Partial<Charge>) =>
    onChange(charges.map((charge) => (charge.id === id ? { ...charge, ...update } : charge)));

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">Charges</h3>
          </header>
        </CardContent>
        {loading ? (
          <CardContent asChild>
            <section>
              <div className="grow text-center">
                <LoadingSpinner className="size-8" />
              </div>
            </section>
          </CardContent>
        ) : charges.length > 0 ? (
          <>
            {remainingCharges !== null ? (
              <CardContent>
                <section>
                  <Alert role="status" variant="info" className="grow">
                    {`${remainingCharges} ${remainingCharges > 1 ? "charges" : "charge"} remaining`}
                  </Alert>
                </section>
              </CardContent>
            ) : null}
            {charges.map((charge) => (
              <CardContent asChild key={charge.id}>
                <ChargeRow
                  purchase={charge}
                  customerEmail={customerEmail}
                  onChange={(update) => updateCharge(charge.id, update)}
                  showRefundFeeNotice={showRefundFeeNotice}
                  canPing={canPing}
                />
              </CardContent>
            ))}
          </>
        ) : (
          <section>
            <div>No charges yet</div>
          </section>
        )}
      </section>
    </Card>
  );
};

const CallSection = ({ call, onChange }: { call: Call; onChange: (call: Call) => void }) => {
  const currentSeller = useCurrentSeller();
  const [isLoading, setIsLoading] = React.useState(false);
  const [callUrl, setCallUrl] = React.useState(call.call_url ?? "");
  const handleSave = async () => {
    setIsLoading(true);
    try {
      await updateCallUrl(call.id, callUrl);
      onChange({ ...call, call_url: callUrl });
      showAlert("Call URL updated!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">Call</h3>
          </header>
        </CardContent>
        <CardContent asChild>
          <section>
            <h5 className="grow font-bold">Start time</h5>
            {formatCallDate(new Date(call.start_time), { timeZone: { userTimeZone: currentSeller?.timeZone.name } })}
          </section>
        </CardContent>
        <CardContent asChild>
          <section>
            <h5 className="grow font-bold">End time</h5>
            {formatCallDate(new Date(call.end_time), { timeZone: { userTimeZone: currentSeller?.timeZone.name } })}
          </section>
        </CardContent>
        <CardContent asChild>
          <section>
            <form
              onSubmit={(evt) => {
                evt.preventDefault();
                void handleSave();
              }}
              className="grow"
            >
              <fieldset>
                <input
                  type="text"
                  value={callUrl}
                  onChange={(evt) => setCallUrl(evt.target.value)}
                  placeholder="Call URL"
                />
                <Button color="primary" type="submit" disabled={isLoading}>
                  {isLoading ? "Saving..." : "Save"}
                </Button>
              </fieldset>
            </form>
          </section>
        </CardContent>
      </section>
    </Card>
  );
};

const FileRow = ({ file, disabled, onDelete }: { file: File; disabled?: boolean; onDelete?: () => void }) => (
  <Row role="listitem">
    <RowContent>
      <FileKindIcon extension={file.extension} />
      <div>
        <h4>{file.name}</h4>
        <ul className="inline">
          <li>{file.extension}</li>
          <li>{FileUtils.getFullFileSizeString(file.size)}</li>
        </ul>
      </div>
    </RowContent>
    <RowActions>
      {onDelete ? (
        <Button color="danger" onClick={onDelete} disabled={disabled} aria-label="Delete">
          <Icon name="trash2" />
        </Button>
      ) : null}
      <NavigationButton
        href={Routes.s3_utility_cdn_url_for_blob_path({ key: file.key })}
        download
        target="_blank"
        disabled={disabled}
        aria-label="Download"
      >
        <Icon name="download-fill" />
      </NavigationButton>
    </RowActions>
  </Row>
);

const CommissionSection = ({
  commission,
  onChange,
}: {
  commission: Commission;
  onChange: (commission: Commission) => void;
}) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const handleFileChange = asyncVoid(async (event: React.ChangeEvent<HTMLInputElement>) => {
    if (!event.target.files?.length) return;

    setIsLoading(true);

    try {
      const filesToUpload = Array.from(event.target.files);

      const blobs = await Promise.all(
        filesToUpload.map(
          (file) =>
            new Promise<Blob>((resolve, reject) => {
              new DirectUpload(file, Routes.rails_direct_uploads_path()).create((error, blob) => {
                if (error) reject(error);
                else resolve(blob);
              });
            }),
        ),
      );

      await updateCommission(commission.id, [
        ...commission.files.map(({ id }) => id),
        ...blobs.map(({ signed_id }) => signed_id),
      ]);

      onChange({
        ...commission,
        files: [
          ...commission.files,
          ...filesToUpload.map((file, index) => ({
            id: blobs[index]?.signed_id ?? "",
            name: FileUtils.getFileNameWithoutExtension(file.name),
            size: file.size,
            extension: FileUtils.getFileExtension(file.name).toUpperCase(),
            key: blobs[index]?.key ?? "",
          })),
        ],
      });

      showAlert("Uploaded successfully!", "success");
    } catch {
      showAlert("Error uploading files. Please try again.", "error");
    } finally {
      setIsLoading(false);
    }
  });

  const handleDelete = async (fileId: string) => {
    try {
      setIsLoading(true);
      await updateCommission(
        commission.id,
        commission.files.filter(({ id }) => id !== fileId).map(({ id }) => id),
      );
      onChange({
        ...commission,
        files: commission.files.filter(({ id }) => id !== fileId),
      });
      showAlert("File deleted successfully!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  const handleCompletion = async () => {
    try {
      setIsLoading(true);
      await completeCommission(commission.id);
      onChange({ ...commission, status: "completed" });
      showAlert("Commission completed!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">Files</h3>
          </header>
        </CardContent>
        <CardContent asChild>
          <section>
            <section className="grid grow gap-2">
              {commission.files.length ? (
                <Rows role="list">
                  {commission.files.map((file) => (
                    <FileRow
                      key={file.id}
                      file={file}
                      onDelete={() => void handleDelete(file.id)}
                      disabled={isLoading}
                    />
                  ))}
                </Rows>
              ) : null}
              <label className={buttonVariants()}>
                <input
                  type="file"
                  onChange={handleFileChange}
                  disabled={isLoading}
                  multiple
                  style={{ display: "none" }}
                />
                <Icon name="paperclip" /> Upload files
              </label>
              {commission.status === "in_progress" ? (
                <Button color="primary" disabled={isLoading} onClick={() => void handleCompletion()}>
                  Submit and mark as complete
                </Button>
              ) : null}
            </section>
          </section>
        </CardContent>
      </section>
    </Card>
  );
};

export default CustomersPage;
