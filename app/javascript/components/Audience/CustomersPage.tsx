import { ArrowInDownSquareHalf, MenuFilter, Truck } from "@boxicons/react";
import { router, useRemember } from "@inertiajs/react";
import cx from "classnames";
import { lightFormat, subMonths } from "date-fns";
import { format } from "date-fns-tz";
import * as React from "react";

import { Customer, Query, SortKey, getPagedCustomers } from "$app/data/customers";
import { CurrencyCode, formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { RecurrenceId, recurrenceLabels } from "$app/utils/recurringPricing";
import { AbortError, assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { DateInput } from "$app/components/DateInput";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { Pagination, PaginationProps } from "$app/components/Pagination";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { PriceInput } from "$app/components/PriceInput";
import { Search } from "$app/components/Search";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Select as FormSelect } from "$app/components/ui/Select";
import { Switch } from "$app/components/ui/Switch";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";
import { useUserAgentInfo } from "$app/components/UserAgent";
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
  license_uses_filter_enabled: boolean;
};

const year = new Date().getFullYear();

const formatPrice = (priceCents: number, currencyType: CurrencyCode, recurrence?: RecurrenceId | null) =>
  `${formatPriceCentsWithCurrencySymbol(currencyType, priceCents, { symbolFormat: "long" })}${
    recurrence ? ` ${recurrenceLabels[recurrence]}` : ""
  }`;

const CustomersPage = ({
  product_id,
  products,
  currency_type,
  countries,
  can_ping,
  show_refund_fee_notice,
  license_uses_filter_enabled,
  ...initialState
}: CustomerPageProps) => {
  const currentSeller = useCurrentSeller();
  const userAgentInfo = useUserAgentInfo();

  const sellerKey = currentSeller?.id ?? "anonymous";
  const [{ customers, pagination, count }, setState] = useRemember<{
    customers: Customer[];
    pagination: PaginationProps | null;
    count: number;
  }>(initialState, `CustomersPage:state:${sellerKey}`);
  const [isLoading, setIsLoading] = React.useState(false);
  const activeRequest = React.useRef<{ cancel: () => void } | null>(null);

  const uid = React.useId();

  const [includedItems, setIncludedItems] = useRemember<Item[]>(
    product_id ? [{ type: "product", id: product_id }] : [],
    `CustomersPage:includedItems:${sellerKey}`,
  );
  const [excludedItems, setExcludedItems] = useRemember<Item[]>([], `CustomersPage:excludedItems:${sellerKey}`);

  const initialUrlParams = typeof window !== "undefined" ? new URLSearchParams(window.location.search) : null;
  const [query, setQuery] = useRemember<Query>(
    {
      page: 1,
      query: initialUrlParams?.get("query") ?? initialUrlParams?.get("email") ?? null,
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
      minimumLicenseUses: null,
    },
    `CustomersPage:query:${sellerKey}`,
  );
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
    minimumLicenseUses,
  } = query;

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
                    <Button size="icon">
                      <MenuFilter className="size-5" />
                    </Button>
                  </PopoverTrigger>
                </WithTooltip>
              </PopoverAnchor>
              <PopoverContent
                className="max-h-[calc(100vh-8rem)] overflow-y-auto p-0"
                onOpenAutoFocus={(e) => e.preventDefault()}
              >
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
                      <Fieldset>
                        <Label htmlFor={`${uid}-minimum-amount`}>Paid more than</Label>
                        <PriceInput
                          id={`${uid}-minimum-amount`}
                          currencyCode={currency_type}
                          cents={minimumAmount}
                          onChange={(minimumAmount) => updateQuery({ minimumAmount })}
                          placeholder="0"
                        />
                      </Fieldset>
                      <Fieldset>
                        <Label htmlFor={`${uid}-maximum-amount`}>Paid less than</Label>
                        <PriceInput
                          id={`${uid}-maximum-amount`}
                          currencyCode={currency_type}
                          cents={maximumAmount}
                          onChange={(maximumAmount) => updateQuery({ maximumAmount })}
                          placeholder="0"
                        />
                      </Fieldset>
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
                      <Fieldset>
                        <Label htmlFor={`${uid}-after-date`}>After</Label>
                        <DateInput
                          id={`${uid}-after-date`}
                          value={createdAfter}
                          onChange={(createdAfter) => updateQuery({ createdAfter })}
                          max={createdBefore || undefined}
                        />
                        <FieldsetDescription
                          suppressHydrationWarning
                        >{`00:00  ${timeZoneAbbreviation}`}</FieldsetDescription>
                      </Fieldset>
                      <Fieldset>
                        <Label htmlFor={`${uid}-before-date`}>Before</Label>
                        <DateInput
                          id={`${uid}-before-date`}
                          value={createdBefore}
                          onChange={(createdBefore) => updateQuery({ createdBefore })}
                          min={createdAfter || undefined}
                        />
                        <FieldsetDescription
                          suppressHydrationWarning
                        >{`11:59 ${timeZoneAbbreviation}`}</FieldsetDescription>
                      </Fieldset>
                    </div>
                  </CardContent>
                  <CardContent>
                    <Fieldset className="grow basis-0">
                      <Label htmlFor={`${uid}-country`}>From</Label>
                      <FormSelect
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
                      </FormSelect>
                    </Fieldset>
                  </CardContent>
                  {license_uses_filter_enabled ? (
                    <CardContent>
                      <Fieldset className="grow basis-0">
                        <Label htmlFor={`${uid}-minimum-license-uses`}>Minimum license uses</Label>
                        <Input
                          id={`${uid}-minimum-license-uses`}
                          type="number"
                          min={0}
                          step={1}
                          value={minimumLicenseUses ?? ""}
                          onChange={(e) => {
                            const value = e.target.value;
                            updateQuery({
                              minimumLicenseUses: value === "" ? null : Math.max(0, Number.parseInt(value, 10) || 0),
                            });
                          }}
                          placeholder="1"
                        />
                        <FieldsetDescription>Number of times the license has been used.</FieldsetDescription>
                      </Fieldset>
                    </CardContent>
                  ) : null}
                  <CardContent>
                    <h4 className="font-bold">
                      <Label htmlFor={`${uid}-active-customers-only`}>Show active customers only</Label>
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
                    <Button size="icon">
                      <ArrowInDownSquareHalf className="size-5" />
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
              <TableCaption>{`All sales (${count.toLocaleString()})`}</TableCaption>
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
                      onClick={() => {
                        window.sessionStorage.setItem("CustomersPage:canGoBack", "1");
                        router.visit(Routes.customer_sale_path(customer.id));
                      }}
                      style={{ cursor: "pointer" }}
                    >
                      <TableCell>
                        {customer.shipping && !customer.shipping.tracking.shipped ? (
                          <WithTooltip tip="Not Shipped">
                            <Truck
                              style={{ marginRight: "var(--spacer-2)" }}
                              aria-label="Not Shipped"
                              className="size-5"
                            />
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
                          <Pill size="small" className="ml-2">
                            UTM
                          </Pill>
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
    <Fieldset className={className}>
      <FieldsetTitle>
        <Label htmlFor={uid}>{label}</Label>
      </FieldsetTitle>
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
    </Fieldset>
  );
};

export default CustomersPage;
