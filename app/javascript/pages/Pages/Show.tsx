import { Head, usePage } from "@inertiajs/react";
import * as React from "react";

import { PoweredByFooter } from "$app/components/PoweredByFooter";

import { buildSrcDoc } from "./srcDoc";

type SellerInfo = {
  name: string;
  username: string;
  avatar_url: string | null;
};

type PageData = {
  title: string;
  html_content: string;
  slug: string;
  seller: SellerInfo;
};

type PageProps = {
  page: PageData;
};

const PagesShow = () => {
  const { page } = usePage<PageProps>().props;

  React.useEffect(() => {
    document.title = page.title;
  }, [page.title]);

  const profileHref = `/${page.seller.username}`;

  return (
    <>
      <Head>
        <title>{page.title}</title>
        <link rel="preload" href="/pages-tailwind.css" as="style" />
      </Head>
      <div className="flex min-h-screen flex-col bg-background">
        <main className="flex-1">
          <iframe
            className="block h-screen w-full border-0"
            title={page.title}
            sandbox="allow-scripts allow-popups"
            srcDoc={buildSrcDoc(page.html_content, { openLinksInNewTab: true, bodyReset: true })}
          />
        </main>
        <aside className="flex items-center justify-center gap-3 border-t border-border bg-background px-4 py-4 text-sm">
          {page.seller.avatar_url ? (
            <img src={page.seller.avatar_url} alt="" className="size-8 rounded-full" />
          ) : null}
          <a href={profileHref} className="font-medium hover:underline">
            {page.seller.name}
          </a>
        </aside>
        <PoweredByFooter />
      </div>
    </>
  );
};

PagesShow.publicLayout = true;
export default PagesShow;
