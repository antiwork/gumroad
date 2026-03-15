import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { useDropbox } from "$app/hooks/useDropbox";

import { ProductEditPage, ProductEditPageProps } from "$app/components/server-components/ProductEditPage";

type PageProps = ProductEditPageProps & {
  dropbox_api_key: string | null;
};

export default function ProductEditInertiaPage() {
  const props = cast<PageProps>(usePage().props);
  const { dropbox_api_key, ...editProps } = props;

  useDropbox(dropbox_api_key);

  return <ProductEditPage {...editProps} />;
}
