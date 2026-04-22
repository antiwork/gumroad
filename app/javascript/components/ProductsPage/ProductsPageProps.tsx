import { Membership, Product, SortKey } from "$app/data/products";

import { PaginationProps } from "$app/components/Pagination";
import { Sort } from "$app/components/useSortingTableDriver";

export type ProductsPageProps = {
  has_products: boolean;
  products_data: {
    products: Product[];
    pagination: PaginationProps;
    sort?: Sort<SortKey> | null | undefined;
  };
  memberships_data: {
    memberships: Membership[];
    pagination: PaginationProps;
    sort?: Sort<SortKey> | null | undefined;
  };
  can_create_product: boolean;
  query: string | null;
};
