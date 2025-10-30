import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import { NoIcon } from "$app/components/Admin/Icons";
import type { Product } from "$app/components/Admin/Products/Product";

type AdminProductFooterProps = {
  product: Product;
};

const AdminProductFooter = ({ product }: AdminProductFooterProps) => (
  <>
    <hr />
    <dl>
      <dt>Updated</dt>
      <dd>
        <DateTimeWithRelativeTooltip date={product.updated_at} />
      </dd>
      <dt>Deleted</dt>
      <dd>
        <DateTimeWithRelativeTooltip date={product.deleted_at} placeholder={<NoIcon />} />
      </dd>
    </dl>
  </>
);

export default AdminProductFooter;
