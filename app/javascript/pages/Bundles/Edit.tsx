import { usePage } from "@inertiajs/react";
import * as React from "react";
import { createBrowserRouter, RouterProvider } from "react-router-dom";
import { cast } from "ts-safe-cast";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { ContentTab } from "$app/components/BundleEdit/ContentTab";
import { ProductTab } from "$app/components/BundleEdit/ProductTab";
import { ShareTab } from "$app/components/BundleEdit/ShareTab";
import { Bundle, BundleEditContext } from "$app/components/BundleEdit/state";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { ProfileSection } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { useRunOnce } from "$app/components/useRunOnce";

const routes = [
  {
    path: "/bundles/:id",
    element: <ProductTab />,
    handle: "product",
  },
  {
    path: "/bundles/:id/content",
    element: <ContentTab />,
    handle: "content",
  },
  {
    path: "/bundles/:id/share",
    element: <ShareTab />,
    handle: "share",
  },
];

type Props = {
  bundle: Bundle;
  id: string;
  unique_permalink: string;
  currency_type: CurrencyCode;
  thumbnail: Thumbnail | null;
  sales_count_for_inventory: number;
  ratings: RatingsWithPercentages;
  taxonomies: Taxonomy[];
  profile_sections: ProfileSection[];
  refund_policies: OtherRefundPolicy[];
  products_count: number;
  is_bundle: boolean;
  has_outdated_purchases: boolean;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
};

export default function BundlesEdit() {
  const {
    bundle: initialBundle,
    id,
    unique_permalink,
    currency_type,
    thumbnail,
    sales_count_for_inventory,
    ratings,
    taxonomies,
    profile_sections,
    refund_policies,
    products_count,
    is_bundle,
    has_outdated_purchases,
    seller_refund_policy_enabled,
    seller_refund_policy,
  } = cast<Props>(usePage().props);

  const [bundle, setBundle] = React.useState(initialBundle);
  const updateBundle = (update: Partial<Bundle> | ((bundle: Bundle) => void)) =>
    setBundle((prevBundle) => {
      const updated = { ...prevBundle };
      if (typeof update === "function") update(updated);
      else Object.assign(updated, update);
      return updated;
    });

  useRunOnce(() => {
    if (!is_bundle)
      showAlert("Select products and save your changes to finish converting this product to a bundle.", "warning");
  });

  const router = createBrowserRouter(routes);

  const contextValue = React.useMemo(
    () => ({
      bundle,
      updateBundle,
      id,
      uniquePermalink: unique_permalink,
      currencyType: currency_type,
      thumbnail,
      salesCountForInventory: sales_count_for_inventory,
      ratings,
      taxonomies,
      profileSections: profile_sections,
      refundPolicies: refund_policies,
      productsCount: products_count,
      hasOutdatedPurchases: has_outdated_purchases,
      seller_refund_policy_enabled,
      seller_refund_policy,
    }),
    [bundle],
  );

  return (
    <BundleEditContext.Provider value={contextValue}>
      <RouterProvider router={router} />
    </BundleEditContext.Provider>
  );
}
