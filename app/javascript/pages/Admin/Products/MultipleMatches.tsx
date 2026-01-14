import { Link, usePage } from "@inertiajs/react";
import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import { Icon } from "$app/components/Icons";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

type ProductMatchProps = {
  external_id: string;
  name: string;
  price_formatted: string;
  long_url: string;
  user: { external_id: string; name: string };
  created_at: string;
};

const ProductMatch = ({ product }: { product: ProductMatchProps }) => {
  const userName =
    product.user.name && product.user.name.length > 0 ? product.user.name : `User ${product.user.external_id}`;

  return (
    <TableRow>
      <TableCell className="space-x-1">
        <span>{product.price_formatted}</span>
        <span>&bull;</span>
        <Link href={Routes.admin_product_url(product.external_id)} title={product.external_id}>
          {product.name}
        </Link>
        <a href={product.long_url} target="_blank" rel="noreferrer noopener">
          <Icon name="arrow-up-right-square" />
        </a>
      </TableCell>

      <TableCell>
        <Link href={Routes.admin_user_path(product.user.external_id)} title={product.user.external_id}>
          {userName}
        </Link>
        <small>
          <DateTimeWithRelativeTooltip date={product.created_at} />
        </small>
      </TableCell>
    </TableRow>
  );
};

const AdminProductsMultipleMatches = () => {
  const { product_matches } = usePage<{ product_matches: ProductMatchProps[] }>().props;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Product</TableHead>
          <TableHead>By</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {product_matches.map((product) => (
          <ProductMatch key={product.external_id} product={product} />
        ))}
      </TableBody>
    </Table>
  );
};

export default AdminProductsMultipleMatches;
