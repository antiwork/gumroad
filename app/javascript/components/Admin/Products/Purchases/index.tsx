import * as React from "react";
import { cast } from "ts-safe-cast";

import { useLazyPaginatedFetch } from "$app/hooks/useLazyFetch";

import AdminProductPurchasesContent from "./Content";
import { type ProductPurchase } from "./Purchase";

type AdminProductPurchasesProps = {
  productExternalId: string;
  isAffiliateUser?: boolean;
  userExternalId: string | null;
};

const AdminProductPurchases = ({
  productExternalId,
  isAffiliateUser = false,
  userExternalId,
}: AdminProductPurchasesProps) => {
  const [open, setOpen] = React.useState(false);

  const url =
    userExternalId && isAffiliateUser
      ? Routes.admin_affiliate_product_purchases_path(userExternalId, productExternalId, { format: "json" })
      : Routes.admin_product_purchases_path(productExternalId, { format: "json" });

  const {
    data: purchases,
    isLoading,
    fetchNextPage,
    hasMore,
  } = useLazyPaginatedFetch<ProductPurchase[]>([], {
    fetchUnlessLoaded: open,
    url,
    responseParser: (data) => {
      const parsed = cast<{ purchases: ProductPurchase[] }>(data);
      return parsed.purchases;
    },
    mode: "append",
  });

  return (
    <>
      <hr />
      <details open={open} onToggle={(e) => setOpen(e.currentTarget.open)}>
        <summary>
          <h3>{isAffiliateUser ? "Affiliate purchases" : "Purchases"}</h3>
        </summary>
        <AdminProductPurchasesContent
          purchases={purchases}
          isLoading={isLoading}
          hasMore={hasMore}
          onLoadMore={() => void fetchNextPage()}
          productExternalId={productExternalId}
        />
      </details>
    </>
  );
};

export default AdminProductPurchases;
