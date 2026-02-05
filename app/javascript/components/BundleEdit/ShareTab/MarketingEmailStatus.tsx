import * as React from "react";

import { CardProduct } from "$app/parsers/product";
import { formatPriceCentsWithCurrencySymbol, CurrencyCode } from "$app/utils/currency";

import { NavigationButton } from "$app/components/Button";
import { Alert } from "$app/components/ui/Alert";

type BundleProduct = CardProduct & {
  is_quantity_enabled: boolean;
  quantity: number;
  variants: {
    selected_id: string;
    list: {
      id: string;
      name: string;
      description: string;
      price_difference: number;
    }[];
  } | null;
};

const computeStandalonePrice = (bundleProduct: BundleProduct) =>
  (bundleProduct.price_cents +
    (bundleProduct.variants?.list.find(({ id }) => id === bundleProduct.variants?.selected_id)?.price_difference ??
      0)) *
  bundleProduct.quantity;

type MarketingEmailStatusProps = {
  id: string;
  isPublished: boolean;
  bundleName?: string;
  bundlePermalink?: string;
  bundlePriceCents?: number;
  products?: BundleProduct[];
  currencyType?: CurrencyCode;
};

export const MarketingEmailStatus = ({
  isPublished,
  bundleName = "",
  bundlePermalink = "",
  bundlePriceCents = 0,
  products = [],
  currencyType = "usd",
}: MarketingEmailStatusProps) => {
  // Only show for published bundles with products
  if (!isPublished || products.length === 0) return null;

  const [sendToAllCustomers, setSendToAllCustomers] = React.useState(false);
  const queryParams = {
    template: "bundle_marketing",
    bundle_product_permalinks: sendToAllCustomers ? undefined : products.map(({ permalink }) => permalink),
    bundle_product_names: products.map(({ name }) => name),
    bundle_permalink: bundlePermalink,
    bundle_name: bundleName,
    bundle_price: formatPriceCentsWithCurrencySymbol(currencyType, bundlePriceCents, {
      symbolFormat: "short",
    }),
    standalone_price: formatPriceCentsWithCurrencySymbol(
      currencyType,
      products.reduce((total, bundleProduct) => total + computeStandalonePrice(bundleProduct), 0),
      { symbolFormat: "short" },
    ),
  };

  return (
    <Alert role="status" variant="info">
      <div className="flex flex-col gap-4">
        <strong>
          Your product bundle is ready. Would you like to send an email about this offer to existing customers?
        </strong>
        <fieldset>
          <label>
            <input
              type="radio"
              checked={!sendToAllCustomers}
              onChange={(evt) => setSendToAllCustomers(!evt.target.checked)}
            />
            Customers who have purchased at least one product in the bundle
          </label>
          <label>
            <input
              type="radio"
              checked={sendToAllCustomers}
              onChange={(evt) => setSendToAllCustomers(evt.target.checked)}
            />
            All customers
          </label>
        </fieldset>
        <NavigationButton
          color="primary"
          href={Routes.new_email_path(queryParams)}
          target="_blank"
          rel="noopener noreferrer"
        >
          Draft and send
        </NavigationButton>
      </div>
    </Alert>
  );
};
