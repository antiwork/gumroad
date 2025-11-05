import { Link, useForm, usePage } from "@inertiajs/react";
import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import EmptyState from "$app/components/Admin/EmptyState";
import PaginatedLoader, { Pagination } from "$app/components/Admin/PaginatedLoader";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { WithTooltip } from "$app/components/WithTooltip";

type Purchase = {
  id: string;
  formatted_display_price: string;
  formatted_gumroad_tax_amount: string;
  gumroad_responsible_for_tax: boolean;
  product: { id: string; name: string; long_url: string };
  variants_list: string;
  purchase_refund_policy: string | null;
  product_refund_policy: string | null;
  seller: { email: string; support_email: string };
  email: string;
  created_at: string;
  purchase_state: string;
  stripe_refunded: boolean;
  stripe_partially_refunded: boolean;
  chargedback: boolean;
  chargeback_reversed: boolean;
  error_code: string | null;
  last_chargebacked_purchase: number | null;
};

export default function Purchases() {
  const { pagination, purchases } = usePage<{ pagination: Pagination; purchases: Purchase[] }>().props;
  const currentUrl = useOriginalLocation();
  const searchParams = new URL(currentUrl).searchParams;
  const { data, setData, get } = useForm({
    query: searchParams.get("query") || "",
    product_title_query: searchParams.get("product_title_query") || "",
    purchase_status: searchParams.get("purchase_status") || "",
  });

  return (
    <div className="paragraphs">
      {purchases.length > 0 ? (
        <>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              get(Routes.admin_search_purchases_path());
            }}
            className="input-with-button"
          >
            <input
              name="product_title_query"
              placeholder="Filter by product title"
              type="text"
              value={data.product_title_query}
              onChange={(e) => setData("product_title_query", e.target.value)}
            />
            <select
              name="purchase_status"
              value={data.purchase_status}
              onChange={(e) => setData("purchase_status", e.target.value)}
            >
              <option value="">Any status</option>
              <option value="chargeback">Chargeback</option>
              <option value="refunded">Refunded</option>
              <option value="failed">Failed</option>
            </select>
            <button type="submit" className="button primary">
              <Icon name="solid-search" />
            </button>
            {data.product_title_query || data.purchase_status ? (
              <Link href={Routes.admin_search_purchases_path({ query: data.query })} className="button secondary">
                Clear
              </Link>
            ) : null}
          </form>
          <table>
            <thead>
              <tr>
                <th>Purchase</th>
                <th>By</th>
              </tr>
            </thead>
            <tbody>
              {purchases.map((purchase) => (
                <tr key={purchase.id}>
                  <td data-label="Purchase">
                    <Link href={Routes.admin_purchase_path(purchase.id)}>
                      {purchase.formatted_display_price}
                      {purchase.gumroad_responsible_for_tax ? ` + ${purchase.formatted_gumroad_tax_amount} VAT` : null}
                    </Link>{" "}
                    <Link href={Routes.admin_link_url(purchase.product.id)}>{purchase.product.name}</Link>{" "}
                    {purchase.variants_list}{" "}
                    <Link href={purchase.product.long_url} target="_blank" rel="noopener noreferrer nofollow">
                      <Icon name="arrow-up-right-square" />
                    </Link>{" "}
                    <ul className="inline">
                      <li>{purchase.purchase_state}</li>
                      {purchase.stripe_refunded ? <li>(refunded)</li> : null}
                      {purchase.stripe_partially_refunded ? <li>(partially refunded)</li> : null}
                      {purchase.chargedback ? (
                        <li>(chargeback{purchase.chargeback_reversed ? " reversed" : ""})</li>
                      ) : null}
                      {purchase.error_code ? (
                        <li>
                          {purchase.last_chargebacked_purchase ? (
                            <Link href={Routes.admin_purchase_path(purchase.last_chargebacked_purchase)}>
                              {purchase.error_code}
                            </Link>
                          ) : (
                            purchase.error_code
                          )}
                        </li>
                      ) : null}
                    </ul>
                    <div className="text-sm">
                      <ul className="inline">
                        {purchase.purchase_refund_policy ? (
                          <li>
                            Refund policy: {purchase.purchase_refund_policy}{" "}
                            {purchase.product_refund_policy ? (
                              <WithTooltip tip={`Current refund policy: ${purchase.product_refund_policy}`}>
                                <Icon name="solid-shield-exclamation" className="text-warning" />
                              </WithTooltip>
                            ) : null}
                          </li>
                        ) : null}
                        <li>
                          Seller: {purchase.seller.email}{" "}
                          <CopyToClipboard text={purchase.seller.email}>
                            <Icon name="outline-duplicate" />
                          </CopyToClipboard>
                        </li>
                        {purchase.seller.support_email ? (
                          <li>Seller support email: {purchase.seller.support_email}</li>
                        ) : null}
                      </ul>
                    </div>
                  </td>
                  <td data-label="By">
                    <Link href={Routes.admin_search_purchases_path({ query: purchase.email })}>{purchase.email}</Link>{" "}
                    <CopyToClipboard text={purchase.email}>
                      <Icon name="outline-duplicate" />
                    </CopyToClipboard>
                    <small>
                      <DateTimeWithRelativeTooltip date={purchase.created_at} />
                    </small>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <PaginatedLoader itemsLength={purchases.length} pagination={pagination} only={["purchases", "pagination"]} />
        </>
      ) : (
        <EmptyState message="No purchases found." />
      )}
    </div>
  );
}
