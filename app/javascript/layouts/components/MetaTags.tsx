import { Head, usePage } from "@inertiajs/react";
import * as React from "react";

export type MetaTag = {
  tagName: string;
  innerContent: string | null;
  headKey: string;
  httpEquiv: string | null;
  [key: string]: string | null;
};

type PageProps = {
  _inertia_meta?: MetaTag[];
};

// https://inertia-rails.dev/cookbook/server-managed-meta-tags#client-side
const MetaTags = () => {
  const { _inertia_meta: meta } = usePage<PageProps>().props;

  if (!meta) {
    return null;
  }

  return (
    <Head>
      {meta.map((meta: MetaTag) => {
        const { tagName, innerContent, headKey, httpEquiv, ...attrs } = meta;

        let stringifiedInnerContent;
        if (innerContent != null) {
          stringifiedInnerContent = typeof innerContent === "string" ? innerContent : JSON.stringify(innerContent);
        }

        return React.createElement(tagName, {
          key: headKey,
          "head-key": headKey,
          ...(httpEquiv ? { "http-equiv": httpEquiv } : {}),
          ...attrs,
          ...(stringifiedInnerContent ? { dangerouslySetInnerHTML: { __html: stringifiedInnerContent } } : {}),
        });
      })}
    </Head>
  );
};

export default MetaTags;
