import { Head } from "@inertiajs/react";
import * as React from "react";

import ToastAlert from "$app/components/server-components/Alert";

export type ProductPageMeta = {
  custom_styles: string | null;
};

type ProductPageHeadProps = {
  meta: ProductPageMeta;
  title?: string | null;
};

export const ProductPageHead = ({ meta, title }: ProductPageHeadProps) => {
  const customStyles = meta.custom_styles ?? "";

  return (
    <Head {...(title ? { title } : {})}>
      {customStyles.trim().length > 0 ? <style dangerouslySetInnerHTML={{ __html: customStyles }} /> : null}
    </Head>
  );
};

export const ProductPageNoScript = () => (
  <noscript>
    <div id="javascript-notice">
      <strong>JavaScript is required to buy this product.</strong>
      Enable JavaScript in your browser settings and refresh this page to continue.
    </div>
  </noscript>
);

export const ProductPageAlert = () => <ToastAlert initial={null} />;
