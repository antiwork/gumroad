import { Head, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Product, useSelectionFromUrl, Props as ProductProps } from "$app/components/Product";

type PageProps = ProductProps & { custom_styles?: string };

const PurchaseProductShowPage = () => {
  const props = cast<PageProps>(usePage().props);
  const [selection, setSelection] = useSelectionFromUrl(props.product);

  return (
    <>
      {props.custom_styles ? (
        <Head>
          <style>{props.custom_styles}</style>
        </Head>
      ) : null}
      <div>
        <section>
          <Product {...props} selection={selection} setSelection={setSelection} />
        </section>
        <PoweredByFooter className="p-0" />
      </div>
    </>
  );
};

PurchaseProductShowPage.loggedInUserLayout = true;
export default PurchaseProductShowPage;
