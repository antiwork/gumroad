import * as React from "react";

import { Alert } from "$app/components/ui/Alert";
import { useUserAgentInfo } from "$app/components/UserAgent";

type FileInfoAttribute = {
  name: string;
  value: string;
};

type CustomAttribute = {
  name: string;
  value: string;
};

type Preorder = {
  release_date_fmt: string;
};

export type DetailsProps = {
  custom_summary: string | null;
  file_info_attributes: FileInfoAttribute[];
  custom_attributes: CustomAttribute[];
  preorder: Preorder | null;
  has_stream_only_files: boolean;
  should_show_sales_count: boolean;
  sales_count: number;
  is_recurring_billing: boolean;
  price_cents: number;
};

type Props = {
  productData: DetailsProps;
};

const ProductAttributesAndInfo = ({ productData }: Props) => {
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

  return hasNoAttributes && preorder == null && !should_show_sales_count && !has_stream_only_files ? (
    <Alert role="status" variant="info">
      No additional details.
    </Alert>
  ) : (
    <div className="grid gap-4">
      {should_show_sales_count ? (
        <Alert variant="info">
          <strong>{sales_count.toLocaleString(userAgentInfo.locale)}</strong> {salesUnit}
          {sales_count === 1 ? "" : "s"}
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
        <div className="stack">
          {custom_summary ? (
            <div>
              <p>{custom_summary}</p>
            </div>
          ) : null}
          {file_info_attributes.concat(custom_attributes).map((fileInfoAttr, i) => (
            <div key={i}>
              <h5>{fileInfoAttr.name}</h5>
              <div>{fileInfoAttr.value}</div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default ProductAttributesAndInfo;
