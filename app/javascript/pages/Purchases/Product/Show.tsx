import { Head, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Product, useSelectionFromUrl, Props as ProductProps } from "$app/components/Product";

type PageProps = ProductProps & {
  custom_styles: string;
};

function PurchaseProductPage() {
  const { product, purchase, discount_code, wishlists, custom_styles } = cast<PageProps>(usePage().props);
  const [selection, setSelection] = useSelectionFromUrl(product);

  return (
    <>
      <Head>
        <style>{custom_styles}</style>
      </Head>
      <section>
        <Product
          product={product}
          purchase={purchase}
          discountCode={discount_code}
          wishlists={wishlists}
          selection={selection}
          setSelection={setSelection}
        />
      </section>
      <PoweredByFooter className="p-0" />
    </>
  );
}

PurchaseProductPage.loggedInUserLayout = true;
export default PurchaseProductPage;
