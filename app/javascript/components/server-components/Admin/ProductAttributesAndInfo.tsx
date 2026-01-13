import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { useUserAgentInfo } from "$app/components/UserAgent";

type Props = {
  productData: {
    custom_summary: string | null;
    file_info_attributes: { name: string; value: string }[];
    custom_attributes: { name: string; value: string }[];
    preorder: { release_date_fmt: string } | null;
    has_stream_only_files: boolean;
    should_show_sales_count: boolean;
    sales_count: number;
    is_recurring_billing: boolean;
    price_cents: number;
  };
};

export const ProductAttributesAndInfo = ({ productData }: Props) => {
  const {
    custom_summary,
    file_info_attributes,
    custom_attributes,
    preorder,
    has_stream_only_files,
    should_show_sales_count,
    sales_count,
    is_recurring_billing,
    price_cents,
  } = productData;
  const userAgentInfo = useUserAgentInfo();

  const salesUnit = is_recurring_billing
    ? "member"
    : preorder != null
      ? "pre-order"
      : price_cents > 0
        ? "sale"
        : "download";

  const hasNoAttributes = custom_summary == null && file_info_attributes.length === 0 && custom_attributes.length === 0;

  return hasNoAttributes && preorder == null && !should_show_sales_count && !has_stream_only_files ? null : (
    <div className="product-info grid gap-4">
      {should_show_sales_count ? (
        <Alert variant="info">
          <div>
            <strong>{sales_count.toLocaleString(userAgentInfo.locale)}</strong> {salesUnit}
            {sales_count === 1 ? "" : "s"}
          </div>
        </Alert>
      ) : null}
      {preorder != null ? (
        <>
          <Alert variant="info">Available on {preorder.release_date_fmt}</Alert>
          <h5 className="product-info-preorder-indicator legacy-only">Available on {preorder.release_date_fmt}</h5>
        </>
      ) : null}

      {has_stream_only_files ? (
        <>
          <Alert variant="info">Watch link provided after purchase</Alert>
          <div className="product-info-stream-only-indicator legacy-only">
            <h5>Available to stream instantly</h5>
            <small>Watch link provided after purchase</small>
          </div>
        </>
      ) : null}
      {hasNoAttributes ? null : (
        <Card>
          {custom_summary ? (
            <CardContent>
              <p className="grow">{custom_summary}</p>
            </CardContent>
          ) : null}
          {file_info_attributes.concat(custom_attributes).map((fileInfoAttr, i) => (
            <CardContent key={i}>
              <h5 className="grow font-bold">{fileInfoAttr.name}</h5>
              <div>{fileInfoAttr.value}</div>
            </CardContent>
          ))}
        </Card>
      )}
    </div>
  );
};

export default register({ component: ProductAttributesAndInfo, propParser: createCast() });
