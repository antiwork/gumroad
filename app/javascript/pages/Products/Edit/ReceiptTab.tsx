// app/javascript/pages/Products/Edit/ReceiptTab.tsx
//
// Inertia page for the Receipt tab of the edit flow.
// Wraps the existing ReceiptTab component with ProductEditContext.
import type { ContentUpdates } from "$app/components/ProductEdit/state";

import * as React from "react";
import { usePage } from "@inertiajs/react";
import { createBrowserRouter, RouterProvider } from "react-router-dom";

import { ReceiptTab } from "$app/components/ProductEdit/ReceiptTab";
import { ProductEditContext } from "$app/components/ProductEdit/state";
import { buildContextValue } from "./shared/contextBuilder";
import type { EditPageProps } from "./shared/types";

const router = createBrowserRouter([
  {
    path: "/products/:id/edit/receipt",
    element: <ReceiptTab />,
    handle: "receipt",
  },
]);

export default function ReceiptTabPage() {
  const { props } = usePage<EditPageProps & Record<string, unknown>>();
  const [product, setProduct] = React.useState(props.product);
  const [existingFiles, setExistingFiles] = React.useState(props.existing_files);
  const [currencyType, setCurrencyType] = React.useState(props.currency_type);
  const [contentUpdates, setContentUpdates] = React.useState<ContentUpdates>(null);
  const [saving, setSaving] = React.useState(false);

  const contextValue = React.useMemo(
    () =>
      buildContextValue(props, {
        product,
        setProduct,
        existingFiles,
        setExistingFiles,
        currencyType,
        setCurrencyType,
        contentUpdates,
        setContentUpdates,
        saving,
        setSaving,
      }),
    [product, existingFiles, currencyType, contentUpdates, saving]
  );

  return (
    <ProductEditContext.Provider value={contextValue}>
      <RouterProvider router={router} />
    </ProductEditContext.Provider>
  );
}
