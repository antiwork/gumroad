import * as React from "react";
import { createCast } from "ts-safe-cast";

import { ProductPurchase, fetchProductPurchases } from "$app/data/admin/admin_product_purchases";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";

const AdminProductPurchases = ({
  product_id,
  is_affiliate_user,
  user_external_id,
}: {
  product_id: number;
  is_affiliate_user: boolean;
  user_external_id: string | null;
}) => {
  const [purchases, setPurchases] = React.useState<ProductPurchase[] | null>(null);
  const [currentPage, setCurrentPage] = React.useState(0);
  const [isLoading, setIsLoading] = React.useState(false);
  const [hasMore, setHasMore] = React.useState(false);

  const purchasesPerPage = 20;

  const loadPurchases = async () => {
    setIsLoading(true);
    try {
      const result = await fetchProductPurchases(
        product_id,
        currentPage + 1,
        purchasesPerPage,
        is_affiliate_user,
        user_external_id,
      );
      setPurchases((prev) => [...(prev ?? []), ...result.purchases]);
      setCurrentPage(result.page || 0);
      setHasMore(result.purchases.length === purchasesPerPage);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <details>
      <summary
        onClick={() => {
          if (!purchases) void loadPurchases();
        }}
      >
        <h3>{is_affiliate_user ? "Affiliate purchases" : "Purchases"}</h3>
      </summary>
      <div className="paragraphs">
        {purchases && purchases.length > 0 ? (
          <Card>
            {purchases.map((purchase) => (
              <CardContent key={purchase.external_id}>
                <div className="grow">
                  <h5 className="font-bold">
                    <a href={Routes.admin_purchase_path(purchase.external_id)}>{purchase.displayed_price}</a>
                    {purchase.gumroad_responsible_for_tax ? ` + ${purchase.formatted_gumroad_tax_amount} VAT` : null}
                  </h5>
                  <small>
                    <ul className="inline">
                      <li>{purchase.purchase_state}</li>
                      {purchase.error_code ? <li>{purchase.error_code}</li> : null}
                      {purchase.is_preorder_authorization ? <li>(pre-order auth)</li> : null}
                      {purchase.stripe_refunded ? (
                        <li>
                          (refunded
                          {purchase.refunded_by.map((refunder) => (
                            <React.Fragment key={refunder.external_id}>
                              {" "}
                              by <a href={Routes.admin_user_path(refunder.external_id)}>{refunder.email}</a>
                            </React.Fragment>
                          ))}
                          )
                        </li>
                      ) : null}
                      {purchase.is_chargedback ? <li>(chargeback)</li> : null}
                      {purchase.is_chargeback_reversed ? <li>(chargeback_reversed)</li> : null}
                    </ul>
                  </small>
                </div>
                <div className="text-right">
                  <a href={Routes.admin_search_purchases_path({ query: purchase.email })}>{purchase.email}</a>
                  <small>{purchase.created}</small>
                </div>
              </CardContent>
            ))}
          </Card>
        ) : null}
        {isLoading ? <LoadingSpinner className="size-3" /> : null}
        {purchases?.length === 0 ? (
          <Alert role="status" variant="info">
            No purchases have been made.
          </Alert>
        ) : null}
        {hasMore ? (
          <button className="button small" onClick={() => void loadPurchases()} disabled={isLoading}>
            {isLoading ? "Loading..." : "Load more"}
          </button>
        ) : null}
      </div>
    </details>
  );
};

export default register({ component: AdminProductPurchases, propParser: createCast() });
