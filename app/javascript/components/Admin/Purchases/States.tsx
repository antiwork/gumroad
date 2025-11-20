import { Link } from "@inertiajs/react";
import React from "react";

export type PurchaseStatesInfo = {
  purchase_state: string;
  stripe_refunded: boolean;
  stripe_partially_refunded: boolean;
  chargedback: boolean;
  chargeback_reversed: boolean;
  error_code: string | null;
  last_chargebacked_purchase: number | null;
};

export const PurchaseStates = ({ purchase }: { purchase: PurchaseStatesInfo }) => (
  <ul className="inline">
    <li>{purchase.purchase_state}</li>
    {purchase.stripe_refunded ? <li>(refunded)</li> : null}
    {purchase.stripe_partially_refunded ? <li>(partially refunded)</li> : null}
    {purchase.chargedback ? <li>(chargeback{purchase.chargeback_reversed ? " reversed" : ""})</li> : null}
    {purchase.error_code ? (
      <li>
        {purchase.last_chargebacked_purchase ? (
          <Link href={Routes.admin_purchase_path(purchase.last_chargebacked_purchase)}>{purchase.error_code}</Link>
        ) : (
          purchase.error_code
        )}
      </li>
    ) : null}
  </ul>
);
