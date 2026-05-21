import { Link, usePage, router } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

import placeholder from "$assets/images/placeholders/dashboard.png";

type PageItem = {
  id: string;
  title: string;
  slug: string;
  published: boolean;
  published_at: string | null;
  updated_at: string;
  is_profile: boolean;
  product_name: string | null;
};

type PageProps = {
  pages: PageItem[];
  can_create_page: boolean;
};

export default function PagesIndex() {
  const { pages, can_create_page } = typia.assert<PageProps>(usePage().props);
  const [deleting, setDeleting] = React.useState<{ slug: string; title: string; state: "confirm" | "deleting" } | null>(
    null,
  );

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
      <section className="p-4 md:p-8">
        {pages.length === 0 ? (
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            <h2>Create your first page</h2>
            <p>Build AI-powered landing pages to showcase your products.</p>
            <div>
              <NavigationButtonInertia href={Routes.new_page_path()} disabled={!can_create_page} color="accent">
                New page
              </NavigationButtonInertia>
            </div>
          </Placeholder>
        ) : (
          <Table aria-live="polite">
            <TableCaption>Pages</TableCaption>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Product</TableHead>
                <TableHead>Updated</TableHead>
                <TableHead>Status</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {pages.map((page) => (
                <TableRow key={page.id}>
                  <TableCell hideLabel>
                    <div>
                      <Link href={Routes.edit_page_path(page.slug)} style={{ textDecoration: "none" }}>
                        <h4 className="font-bold">
                          {page.title}
                          {page.is_profile ? (
                            <span className="ml-2 text-xs font-normal text-muted">· Profile</span>
                          ) : null}
                        </h4>
                      </Link>
                      <small className="block">/pages/{page.slug}</small>
                    </div>
                  </TableCell>
                  <TableCell label="Product" className="whitespace-nowrap">
                    {page.product_name ?? "—"}
                  </TableCell>
                  <TableCell label="Updated" className="whitespace-nowrap">
                    {new Date(page.updated_at).toLocaleDateString()}
                  </TableCell>
                  <TableCell label="Status" className="whitespace-nowrap">
                    {page.published ? "Published" : "Draft"}
                  </TableCell>
                  <TableCell>
                    <div className="flex flex-wrap gap-2 lg:justify-end">
                      <Button asChild>
                        <Link href={Routes.edit_page_path(page.slug)}>Edit</Link>
                      </Button>
                      <Button
                        color="danger"
                        outline
                        onClick={() => setDeleting({ slug: page.slug, title: page.title, state: "confirm" })}
                      >
                        Delete
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </section>
      {deleting ? (
        <Modal
          open
          onClose={() => setDeleting(null)}
          title="Delete page?"
          footer={
            <>
              <Button disabled={deleting.state === "deleting"} onClick={() => setDeleting(null)}>
                Cancel
              </Button>
              {deleting.state === "deleting" ? (
                <Button color="danger" disabled>
                  Deleting...
                </Button>
              ) : (
                <Button
                  color="danger"
                  onClick={() => {
                    setDeleting({ ...deleting, state: "deleting" });
                    router.delete(Routes.page_path(deleting.slug), {
                      onError: () => {
                        setDeleting((prev) => (prev ? { ...prev, state: "confirm" } : prev));
                        showAlert("Sorry, something went wrong. Please try again.", "error");
                      },
                    });
                  }}
                >
                  Delete
                </Button>
              )}
            </>
          }
        >
          <h4>Are you sure you want to delete "{deleting.title}"? This cannot be undone.</h4>
        </Modal>
      ) : null}
    </div>
  );
}
