import { Link, usePage, router } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { Button } from "$app/components/Button";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Placeholder } from "$app/components/ui/Placeholder";

type PageItem = {
  id: string;
  title: string;
  slug: string;
  published: boolean;
  published_at: string | null;
  updated_at: string;
  product_name: string | null;
};

type PageProps = {
  pages: PageItem[];
  can_create_page: boolean;
};

export default function PagesIndex() {
  const { pages, can_create_page } = typia.assert<PageProps>(usePage().props);

  const deletePage = (slug: string) => {
    if (!confirm("Are you sure you want to delete this page?")) return;
    router.delete(Routes.page_path(slug));
  };

  return (
    <div>
      <PageHeader
        title="Pages"
        actions={
          <NavigationButtonInertia href={Routes.new_page_path()} disabled={!can_create_page} color="accent">
            New page
          </NavigationButtonInertia>
        }
      />
      {pages.length === 0 ? (
        <Placeholder>
          <h2>Create your first page</h2>
          <p>Build AI-powered landing pages to showcase your products.</p>
        </Placeholder>
      ) : (
        <div className="grid gap-4 p-4 md:p-8">
          {pages.map((page) => (
            <div key={page.id} className="flex items-center justify-between rounded-lg border border-border p-4">
              <div className="flex flex-col gap-1">
                <Link href={Routes.edit_page_path(page.slug)} className="font-bold hover:underline">
                  {page.title}
                </Link>
                <div className="flex items-center gap-2 text-sm text-muted">
                  <span>/pages/{page.slug}</span>
                  {page.product_name ? <span>· {page.product_name}</span> : null}
                  <span>· {new Date(page.updated_at).toLocaleDateString()}</span>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${page.published ? "bg-green-100 text-green-800" : "bg-gray-100 text-gray-600"}`}>
                  {page.published ? "Published" : "Draft"}
                </span>
                <Button asChild>
                  <Link href={Routes.edit_page_path(page.slug)}>Edit</Link>
                </Button>
                <Button color="danger" onClick={() => deletePage(page.slug)}>
                  Delete
                </Button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
