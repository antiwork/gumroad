import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { Bundle, BundleEditContext } from "$app/components/BundleEdit/state";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { ProfileSection } from "$app/components/ProductEdit/state";

export type BundleEditRoutes = {
  product: string;
  content: string;
  share: string;
};

export type BundleEditPageProps = {
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
  routes: BundleEditRoutes;
};

type BundleEditProviderContextType = {
  bundle: Bundle;
  updateBundle: (update: Partial<Bundle> | ((bundle: Bundle) => void)) => void;
  id: string;
  uniquePermalink: string;
  currencyType: CurrencyCode;
  thumbnail: Thumbnail | null;
  setThumbnail: React.Dispatch<React.SetStateAction<Thumbnail | null>>;
  salesCountForInventory: number;
  ratings: RatingsWithPercentages;
  taxonomies: Taxonomy[];
  profileSections: ProfileSection[];
  refundPolicies: OtherRefundPolicy[];
  productsCount: number;
  hasOutdatedPurchases: boolean;
  sellerRefundPolicyEnabled: boolean;
  sellerRefundPolicy: Pick<RefundPolicy, "title" | "fine_print">;
  routes: BundleEditRoutes;
};

const BundleEditProviderContext = React.createContext<BundleEditProviderContextType | null>(null);

export const useBundleEditProvider = () => {
  const context = React.useContext(BundleEditProviderContext);
  if (!context) {
    throw new Error("useBundleEditProvider must be used within a BundleEditProvider");
  }
  return context;
};

export const BundleEditProvider = ({ children }: { children: React.ReactNode }) => {
  const {
    bundle: initialBundle,
    id,
    unique_permalink,
    currency_type,
    thumbnail: initialThumbnail,
    sales_count_for_inventory,
    ratings,
    taxonomies,
    profile_sections,
    refund_policies,
    products_count,
    has_outdated_purchases,
    seller_refund_policy_enabled,
    seller_refund_policy,
    routes,
  } = cast<BundleEditPageProps>(usePage().props);

  const [bundle, setBundle] = React.useState(initialBundle);
  React.useEffect(() => setBundle(initialBundle), [initialBundle]);

  const updateBundle = React.useCallback((update: Partial<Bundle> | ((bundle: Bundle) => void)) => {
    setBundle((prevBundle) => {
      if (typeof update === "function") {
        const updated = { ...prevBundle };
        update(updated);
        return updated;
      }
      return { ...prevBundle, ...update };
    });
  }, []);

  const [thumbnail, setThumbnail] = React.useState(initialThumbnail);
  React.useEffect(() => setThumbnail(initialThumbnail), [initialThumbnail]);

  const providerValue = React.useMemo(
    () => ({
      bundle,
      updateBundle,
      id,
      uniquePermalink: unique_permalink,
      currencyType: currency_type,
      thumbnail,
      setThumbnail,
      salesCountForInventory: sales_count_for_inventory,
      ratings,
      taxonomies,
      profileSections: profile_sections,
      refundPolicies: refund_policies,
      productsCount: products_count,
      hasOutdatedPurchases: has_outdated_purchases,
      sellerRefundPolicyEnabled: seller_refund_policy_enabled,
      sellerRefundPolicy: seller_refund_policy,
      routes,
    }),
    [bundle, thumbnail, updateBundle],
  );

  // Also provide the legacy BundleEditContext for child components that still use it
  const legacyContextValue = React.useMemo(
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
    [bundle, thumbnail, updateBundle],
  );

  return (
    <BundleEditProviderContext.Provider value={providerValue}>
      <BundleEditContext.Provider value={legacyContextValue}>{children}</BundleEditContext.Provider>
    </BundleEditProviderContext.Provider>
  );
};
