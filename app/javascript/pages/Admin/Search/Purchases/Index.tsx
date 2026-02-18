import { Link, useForm, usePage } from "@inertiajs/react";
import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import EmptyState from "$app/components/Admin/EmptyState";
import PaginatedLoader, { Pagination } from "$app/components/Admin/PaginatedLoader";
import { type RefundPolicy, RefundPolicyTitle } from "$app/components/Admin/Purchases/RefundPolicy";
import { PurchaseStates } from "$app/components/Admin/Purchases/States";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { Input } from "$app/components/ui/Input";
import { Select } from "$app/components/ui/Select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type Purchase = {
  external_id: string;
  formatted_display_price: string;
  formatted_gumroad_tax_amount: string | null;
  gumroad_responsible_for_tax: boolean;
  product: { external_id: string; name: string; long_url: string };
  variants_list: string;
  refund_policy: RefundPolicy | null;
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
  last_chargebacked_purchase: string | null;
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
    <div className="flex flex-col gap-4">
      {purchases.length > 0 ? (
        <>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              get(Routes.admin_search_purchases_path());
            }}
            className="flex gap-2"
          >
            <Input
              name="product_title_query"
              placeholder="Filter by product title"
              type="text"
              value={data.product_title_query}
              onChange={(e) => setData("product_title_query", e.target.value)}
            />
            <Select
              name="purchase_status"
              value={data.purchase_status}
              wrapperClassName="w-auto shrink-0"
              onChange={(e) => setData("purchase_status", e.target.value)}
            >
              <option value="">Any status</option>
              <option value="chargeback">Chargeback</option>
              <option value="refunded">Refunded</option>
              <option value="failed">Failed</option>
            </Select>
            <Button type="submit" color="primary">
              <Icon name="solid-search" />
            </Button>
            {data.product_title_query || data.purchase_status ? (
              <Button asChild>
                <Link href={Routes.admin_search_purchases_path({ query: data.query })}>Clear</Link>
              </Button>
            ) : null}
          </form>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Purchase</TableHead>
                <TableHead>By</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {purchases.map((purchase) => (
                <TableRow key={purchase.external_id}>
                  <TableCell>
                    <Link href={Routes.admin_purchase_path(purchase.external_id)}>
                      {purchase.formatted_display_price}
                      {purchase.gumroad_responsible_for_tax ? ` + ${purchase.formatted_gumroad_tax_amount} VAT` : null}
                    </Link>{" "}
                    <Link href={Routes.admin_product_url(purchase.product.external_id)}>{purchase.product.name}</Link>{" "}
                    {purchase.variants_list}{" "}
                    <a href={purchase.product.long_url} target="_blank" rel="noopener noreferrer nofollow">
                      <Icon name="arrow-up-right-square" />
                    </a>{" "}
                    <PurchaseStates purchase={purchase} />
                    <div className="text-sm">
                      <ul className="inline">
                        {purchase.refund_policy ? (
                          <li>
                            <RefundPolicyTitle refundPolicy={purchase.refund_policy} />
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
                  </TableCell>
                  <TableCell>
                    <Link href={Routes.admin_search_purchases_path({ query: purchase.email })}>{purchase.email}</Link>{" "}
                    <CopyToClipboard text={purchase.email}>
                      <Icon name="outline-duplicate" />
                    </CopyToClipboard>
                    <small>
                      <DateTimeWithRelativeTooltip date={purchase.created_at} />
                    </small>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <PaginatedLoader itemsLength={purchases.length} pagination={pagination} only={["purchases", "pagination"]} />
        </>
      ) : (
        <EmptyState message="No purchases found." />
      )}
    </div>
  );
}
