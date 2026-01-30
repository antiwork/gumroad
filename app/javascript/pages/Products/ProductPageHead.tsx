import { Head } from "@inertiajs/react";
import * as React from "react";

import ToastAlert from "$app/components/server-components/Alert";

export type ProductPageMeta = {
  custom_styles: string | null;
};

type ProductPageHeadProps = {
  meta: ProductPageMeta;
};

export const ProductPageHead = ({ meta }: ProductPageHeadProps) => {
  const customStyles = meta.custom_styles ?? "";

  if (customStyles.trim().length === 0) return null;

  return (
    <Head>
      <style dangerouslySetInnerHTML={{ __html: customStyles }} />
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
