import { Link } from "@inertiajs/react";
import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import { type Product } from "$app/components/Admin/Products/Product";
import AdminProductStats from "$app/components/Admin/Products/Stats";
import { type User } from "$app/components/Admin/Users/User";

type Props = {
  user: User;
  product: Product;
  isCurrentUrl: boolean;
};

const AdminUsersProductsHeader = ({ product, user, isCurrentUrl }: Props) => (
  <div className="paragraphs">
    <div className="flex items-center gap-4">
      {product.preview_url ? (
        <a href={product.preview_url} target="_blank" rel="noreferrer noopener">
          <img src={product.preview_url} alt="Preview image" style={{ width: "var(--form-element-height)" }} />
        </a>
      ) : (
        <img
          src={product.cover_placeholder_url}
          alt="Cover placeholder"
          style={{ width: "var(--form-element-height)" }}
        />
      )}

      <div className="grid gap-2">
        <h2>
          {product.price_formatted},
          {isCurrentUrl ? product.name : <Link href={Routes.admin_product_path(product.id)}>{product.name}</Link>}
        </h2>

        <div>
          <ul className="inline">
            <li>
              <DateTimeWithRelativeTooltip date={product.created_at} />
            </li>
            <li>
              <Link href={Routes.admin_user_path(user.id)}>{user.name}</Link>
            </li>
            <AdminProductStats product_id={product.id} />
          </ul>
        </div>
      </div>
    </div>

    <div className="button-group">
      <a
        href={Routes.edit_link_path(product.unique_permalink)}
        className="button small"
        target="_blank"
        rel="noreferrer"
      >
        Edit
      </a>
      {product.admins_can_generate_url_redirects ? (
        <a
          href={Routes.generate_url_redirect_admin_link_path(product.id)}
          className="button small"
          target="_blank"
          rel="noreferrer noopener"
        >
          View download page
        </a>
      ) : null}
      {product.alive_product_files.map((file) => (
        <a
          key={file.external_id}
          href={Routes.admin_access_product_file_admin_product_path(product.id, file.external_id)}
          className="button small"
          target="_blank"
          rel="noreferrer noopener"
        >
          {file.s3_filename}
        </a>
      ))}
    </div>
  </div>
);

export default AdminUsersProductsHeader;
