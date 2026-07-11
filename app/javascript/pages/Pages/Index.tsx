import { FileDetail, MagicWand, Pencil, Store, Trash } from "@boxicons/react";
import { Link, router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { Button, NavigationButton } from "$app/components/Button";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
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
// storefront root, sits first in the list, and can't be deleted.
type ProfileEntry = {
  title: string;
  username: string;
  profile_url: string;
  custom_html: boolean;
};

export default function PagesIndex() {
  const { pages, profile } = typia.assert<{ pages: PageEntry[]; profile: ProfileEntry }>(usePage().props);
  const loggedInUser = useLoggedInUser();
  const canManage = !!loggedInUser?.policies.page.create;
  const [deleting, setDeleting] = React.useState<{ slug: string; title: string; busy: boolean } | null>(null);

  const newPageButton = (
    <Button asChild color="accent">
      <Link
        href={Routes.new_page_path()}
        inert={!canManage || undefined}
        className={!canManage ? "opacity-30" : undefined}
      >
        New page
      </Link>
    </Button>
  );

  return (
    <>
      <PageHeader className="sticky-top" title="Pages" actions={newPageButton} />
      <section className="grid gap-4 p-4 md:p-8">
        <p className="max-w-prose text-muted">
          Your profile is the home page of your store. Every other page lives under it at its own link — use them for
          about pages, licenses, FAQs, or anything else your audience needs.
        </p>

        <Rows role="list">
          {/* The profile row: pinned first, undeletable. It renders the default
              storefront template until the seller (or their agent) replaces it
              with fully custom HTML. */}
          <Row role="listitem">
            <RowContent className="gap-4">
              <div className="flex size-10 shrink-0 items-center justify-center rounded bg-black text-white dark:bg-white dark:text-black">
                <Store pack="filled" className="size-5" />
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-2">
                  <Link href={Routes.edit_page_path("profile")} className="truncate font-medium hover:underline">
                    {profile.title}
                  </Link>
                  <Pill size="small">Home</Pill>
                  {profile.custom_html ? <Pill size="small">Custom HTML</Pill> : null}
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
              <span className="hidden text-sm text-muted sm:block">Default template</span>
              <NavigationButton size="icon" href={Routes.edit_page_path("profile")} aria-label="Edit profile page">
                <Pencil className="size-4" />
              </NavigationButton>
            </RowActions>
          </Row>

          {/* Every other page hangs off the profile at its slug. */}
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
                <Button
                  size="icon"
                  outline
                  color="danger"
                  disabled={!canManage}
                  aria-label={`Delete ${page.title}`}
                  onClick={() => setDeleting({ slug: page.slug, title: page.title, busy: false })}
                >
                  <Trash className="size-4" />
                </Button>
              </RowActions>
            </Row>
          ))}
        </Rows>
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
                    onError: () => setDeleting({ ...deleting, busy: false }),
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
