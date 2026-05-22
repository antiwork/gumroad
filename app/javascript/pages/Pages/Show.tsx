import { Head, usePage } from "@inertiajs/react";
import * as React from "react";

import { buildSrcDoc } from "./srcDoc";

type PageProps = {
  page: {
    title: string;
    html_content: string;
    slug: string;
    seller: {
      name: string;
      username: string;
      avatar_url: string | null;
    };
  };
};

export default function PageShow() {
  const { page } = usePage().props as PageProps;
  const [loaded, setLoaded] = React.useState(false);

  return (
    <>
      <Head>
        <link rel="preload" href="/pages-tailwind.css" as="style" />
      </Head>
      <div className="min-h-screen bg-dark-gray">
        <iframe
          className={`h-screen w-full border-0 transition-opacity duration-300 ${loaded ? "opacity-100" : "opacity-0"}`}
          title={page.title}
          sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox allow-top-navigation-by-user-activation allow-forms"
          srcDoc={buildSrcDoc(page.html_content, { bodyReset: true })}
          onLoad={() => setLoaded(true)}
        />
      </div>
    </>
  );
}
