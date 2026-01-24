import { Head } from "@inertiajs/react";
import * as React from "react";

import ToastAlert from "$app/components/server-components/Alert";

export type ProductPageMeta = {
  canonical: string;
  structured_data: unknown[] | null;
  custom_styles: string | null;
};

type ProductPageHeadProps = {
  meta: ProductPageMeta;
  title?: string | null;
};

export const ProductPageHead = ({ meta, title }: ProductPageHeadProps) => {
  const structuredData = meta.structured_data ?? [];
  const customStyles = meta.custom_styles ?? "";

  return (
    <Head {...(title ? { title } : {})}>
      {meta.canonical ? <link rel="canonical" href={meta.canonical} /> : null}
      {customStyles.trim().length > 0 ? <style dangerouslySetInnerHTML={{ __html: customStyles }} /> : null}
      {structuredData.length > 0 ? (
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(structuredData) }} />
      ) : null}
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
