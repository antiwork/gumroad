import { Link, usePage } from "@inertiajs/react";
import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import { Icon } from "$app/components/Icons";

type ProductMatchProps = {
  id: number;
  name: string;
  price_formatted: string;
  long_url: string;
  user: { id: number; name: string };
  created_at: string;
};

const ProductMatch = ({ product }: { product: ProductMatchProps }) => {
  const userName = product.user.name && product.user.name.length > 0 ? product.user.name : `User ${product.user.id}`;

  return (
    <tr>
      <td data-label="Product" className="space-x-1">
        <span>{product.price_formatted}</span>
        <span>&bull;</span>
        <Link href={Routes.admin_product_url(product.id)} title={product.id.toString()}>
          {product.name}
        </Link>
        <a href={product.long_url} target="_blank" rel="noreferrer noopener">
          <Icon name="arrow-up-right-square" />
        </a>
      </td>

      <td data-label="By">
        <Link href={Routes.admin_user_path(product.user.id)} title={product.user.id.toString()}>
          {userName}
        </Link>
        <small>
          <DateTimeWithRelativeTooltip date={product.created_at} />
        </small>
      </td>
    </tr>
  );
};

const AdminProductsMultipleMatches = () => {
  const { product_matches } = usePage<{ product_matches: ProductMatchProps[] }>().props;

  return (
    <table>
      <thead>
        <tr>
          <th>Product</th>
          <th>By</th>
        </tr>
      </thead>
      <tbody>
        {product_matches.map((product) => (
          <ProductMatch key={product.id} product={product} />
        ))}
      </tbody>
    </table>
  );
};

export default AdminProductsMultipleMatches;
