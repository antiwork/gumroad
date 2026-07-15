import { ArrowRight, Box, FileDetail, MagicWand, Pencil, Store, Trash } from "@boxicons/react";
import { Link, router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { Button, NavigationButton } from "$app/components/Button";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { Placeholder } from "$app/components/ui/Placeholder";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";

// A regular custom page owned by the seller. `custom_html` pages were built by
// an agent/CLI as full HTML, so the in-app editor shows a preview + agent path
// instead of the rich text editor.
type PageEntry = {
  slug: string;
  title: string;
  content: string;
  custom_html: boolean;
};

// The profile is the special root of the page tree: it serves at the
// storefront root, sits first in the list (as "Home"), and can't be deleted.
type ProfileEntry = {
  username: string;
  profile_url: string;
  custom_html: boolean;
};

export default function PagesIndex() {
  const { pages, profile, product_pages_count } = typia.assert<{
    pages: PageEntry[];
    profile: ProfileEntry;
    product_pages_count: number;
  }>(usePage().props);
  const loggedInUser = useLoggedInUser();
  const canManage = !!loggedInUser?.policies.page.create;
  const [deleting, setDeleting] = React.useState<{ slug: string; title: string; busy: boolean } | null>(null);

  return (
    <>
      <PageHeader
        className="sticky-top"
        title="Pages"
        actions={
          // Roles that can't create pages don't get a button whose request
          // would fail — they can still browse the list and open pages.
          canManage ? (
            <Button asChild color="accent">
              <Link href={Routes.new_page_path()}>New page</Link>
            </Button>
          ) : undefined
        }
      />
      <section className="grid gap-4 p-4 md:p-8">
        <Rows role="list">
          {/* The home row: pinned first, undeletable. It renders the default
              storefront template until the seller (or their agent) replaces it
              with fully custom HTML — one state or the other, never both. */}
          <Row role="listitem">
            <RowContent className="gap-4">
              <div className="flex size-10 shrink-0 items-center justify-center rounded bg-black text-white dark:bg-white dark:text-black">
                <Store pack="filled" className="size-5" />
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-2">
                  <Link href={Routes.edit_page_path("profile")} className="truncate font-medium hover:underline">
                    Home
                  </Link>
                </div>
                <a
                  href={profile.profile_url}
                  target="_blank"
                  rel="noreferrer"
                  className="block truncate text-sm text-muted hover:underline"
                >
                  {profile.profile_url.replace(/^https?:\/\//u, "")}
                </a>
              </div>
            </RowContent>
            <RowActions>
              <span className="hidden text-sm text-muted sm:block">
                {profile.custom_html ? "Custom HTML" : "Default template"}
              </span>
              <NavigationButton size="icon" href={Routes.edit_page_path("profile")} aria-label="Edit home page">
                <Pencil className="size-4" />
              </NavigationButton>
            </RowActions>
          </Row>

          {/* Every other page hangs off the home page at its slug. */}
          {pages.map((page) => (
            <Row key={page.slug} role="listitem" className="sm:pl-8">
              <RowContent className="gap-4">
                <div className="flex size-10 shrink-0 items-center justify-center rounded border border-border text-muted">
                  {page.custom_html ? <MagicWand className="size-5" /> : <FileDetail className="size-5" />}
                </div>
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <Link href={Routes.edit_page_path(page.slug)} className="truncate font-medium hover:underline">
                      {page.title}
                    </Link>
                    {page.custom_html ? <Pill size="small">Custom HTML</Pill> : null}
                  </div>
                  <a
                    href={`${profile.profile_url.replace(/\/$/u, "")}/${page.slug}`}
                    target="_blank"
                    rel="noreferrer"
                    className="block truncate text-sm text-muted hover:underline"
                  >
                    {`${profile.profile_url.replace(/^https?:\/\//u, "").replace(/\/$/u, "")}/${page.slug}`}
                  </a>
                </div>
              </RowContent>
              <RowActions>
                <NavigationButton size="icon" href={Routes.edit_page_path(page.slug)} aria-label={`Edit ${page.title}`}>
                  <Pencil className="size-4" />
                </NavigationButton>
                {canManage ? (
                  <Button
                    size="icon"
                    outline
                    color="danger"
                    aria-label={`Delete ${page.title}`}
                    onClick={() => setDeleting({ slug: page.slug, title: page.title, busy: false })}
                  >
                    <Trash className="size-4" />
                  </Button>
                ) : null}
              </RowActions>
            </Row>
          ))}

          {/* Product pages are edited from each product's Share tab, not here.
              This row only appears once a product actually has a custom page,
              sits after the seller's own pages, and navigates to Products —
              hence the arrow instead of a pencil. */}
          {product_pages_count > 0 ? (
            <Row role="listitem" className="sm:pl-8">
              <RowContent className="gap-4">
                <div className="flex size-10 shrink-0 items-center justify-center rounded border border-border text-muted">
                  <Box className="size-5" />
                </div>
                <div className="min-w-0 flex-1">
                  <Link href={Routes.products_path()} className="truncate font-medium hover:underline">
                    Product pages
                  </Link>
                  <span className="block truncate text-sm text-muted">
                    Edited from each product's Share tab in Products
                  </span>
                </div>
              </RowContent>
              <RowActions>
                <span className="hidden text-sm text-muted sm:block">
                  {product_pages_count === 1 ? "1 page" : `${product_pages_count} pages`}
                </span>
                <NavigationButton size="icon" href={Routes.products_path()} aria-label="Open Products">
                  <ArrowRight className="size-4" />
                </NavigationButton>
              </RowActions>
            </Row>
          ) : null}
        </Rows>

        {pages.length === 0 ? (
          // The Home row above stays visible even with no slugged pages yet —
          // it's the only way to reach the profile editor (and remove a custom
          // HTML takeover) now that the old Settings flow is gone. The empty
          // state renders below it as guidance, not as a replacement.
          <Placeholder>
            <h2>No pages yet</h2>
            Add pages to your store — an about page, FAQs, licenses, anything your audience needs. Each page gets its
            own URL under your store.
            {canManage ? (
              <Button asChild color="accent">
                <Link href={Routes.new_page_path()}>New page</Link>
              </Button>
            ) : null}
          </Placeholder>
        ) : null}
      </section>

      {deleting ? (
        <Modal
          open
          allowClose={!deleting.busy}
          onClose={() => setDeleting(null)}
          title="Delete page?"
          footer={
            <>
              <Button disabled={deleting.busy} onClick={() => setDeleting(null)}>
                Cancel
              </Button>
              <Button
                color="danger"
                disabled={deleting.busy}
                onClick={() => {
                  setDeleting({ ...deleting, busy: true });
                  router.delete(Routes.page_path(deleting.slug), {
                    onSuccess: () => setDeleting(null),
                    onError: () => {
                      showAlert("Failed to delete the page. Please try again.", "error");
                      setDeleting({ ...deleting, busy: false });
                    },
                  });
                }}
              >
                {deleting.busy ? "Deleting..." : "Delete"}
              </Button>
            </>
          }
        >
          <h4>
            Are you sure you want to delete "{deleting.title}"? Visitors will no longer be able to open it. This action
            cannot be undone.
          </h4>
        </Modal>
      ) : null}
    </>
  );
}
