import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { paramsToQueryString } from "$app/utils/url";

import { computeStandalonePrice, useBundleEditContext } from "$app/components/BundleEdit/state";
import { NavigationButton } from "$app/components/Button";
import { newEmailPath } from "$app/components/server-components/EmailsPage";

export const MarketingEmailStatus = () => {
  const { bundle, uniquePermalink, currencyType } = useBundleEditContext();

  const [sendToAllCustomers, setSendToAllCustomers] = React.useState(false);
  const queryParams = {
    template: "bundle_marketing",
    bundle_product_permalinks: sendToAllCustomers ? undefined : bundle.products.map(({ permalink }) => permalink),
    bundle_product_names: bundle.products.map(({ name }) => name),
    bundle_permalink: uniquePermalink,
    bundle_name: bundle.name,
    bundle_price: formatPriceCentsWithCurrencySymbol(currencyType, bundle.price_cents, {
      symbolFormat: "short",
    }),
    standalone_price: formatPriceCentsWithCurrencySymbol(
      currencyType,
      bundle.products.reduce((total, bundleProduct) => total + computeStandalonePrice(bundleProduct), 0),
      { symbolFormat: "short" },
    ),
  };

  return (
    <div role="status" className="info">
      <div className="paragraphs">
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
        <NavigationButton color="primary" href={`${newEmailPath}?${paramsToQueryString(queryParams)}`} target="_blank">
          Draft and send
        </NavigationButton>
      </div>
    </div>
  );
};
