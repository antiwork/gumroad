import * as React from "react";

import { Button } from "$app/components/Button";

// Shared logic for the "Customize page" / "Edit page" CTA that appears on
// the Share tab (for product landing pages) and the Profile settings page
// (for profile pages). Both surfaces:
//   1. probe /pages on mount to see if the seller already has a page for
//      this owner (product/profile),
//   2. POST /pages to create one if not, then redirect to the editor,
//   3. flip the button label between "Customize page" and "Edit page".
// The wrapper chrome (Fieldset vs <section>) stays in the caller so each
// editor surface keeps its native styling; only the shared lookup +
// create + navigate flow lives here.
type CreatePagePromptHookArgs = {
  // Query string appended to /pages for the existence probe — for example
  // `product_id=abc` or `is_profile=true`. Callers must include the
  // discriminator that scopes PagesController#index.
  existsQuery: string;
  // Body forwarded to POST /pages. Used directly as the `page:` payload;
  // PagesController#create defaults missing fields server-side (title
  // falls back to product name or DEFAULT_TITLE).
  createBody: Record<string, unknown>;
};

type CreatePagePromptHookResult = {
  existingPageSlug: string | null;
  creating: boolean;
  error: string | null;
  customize: () => Promise<void>;
};

const goToEditor = (slug: string) => {
  window.location.href = `/pages/${slug}/edit?fullscreen=1`;
};

export const useCreatePagePrompt = ({
  existsQuery,
  createBody,
}: CreatePagePromptHookArgs): CreatePagePromptHookResult => {
  const [existingPageSlug, setExistingPageSlug] = React.useState<string | null>(null);
  const [creating, setCreating] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  React.useEffect(() => {
    if (!existsQuery) return;
    let cancelled = false;
    fetch(`/pages?${existsQuery}`, {
      headers: { Accept: "application/json" },
      credentials: "same-origin",
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`Page lookup failed: ${r.status}`))))
      .then((data: { pages: { slug: string }[] }) => {
        if (!cancelled && data.pages[0]) setExistingPageSlug(data.pages[0].slug);
      })
      .catch(() => {
        /* silent — falls back to the "Customize page" CTA */
      });
    return () => {
      cancelled = true;
    };
  }, [existsQuery]);

  const customize = React.useCallback(async () => {
    if (existingPageSlug) {
      goToEditor(existingPageSlug);
      return;
    }
    setCreating(true);
    setError(null);
    try {
      const res = await fetch("/pages", {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": (document.querySelector('meta[name="csrf-token"]') as HTMLMetaElement | null)?.content ?? "",
        },
        credentials: "same-origin",
        body: JSON.stringify({ page: createBody }),
      });
      const data: { success: boolean; slug?: string; error?: string } = await res.json();
      if (!res.ok || !data.success || !data.slug) {
        setError(data.error ?? "Could not create page.");
        return;
      }
      goToEditor(data.slug);
    } catch {
      setError("Network error. Please try again.");
    } finally {
      setCreating(false);
    }
  }, [existingPageSlug, createBody]);

  return { existingPageSlug, creating, error, customize };
};

type CreatePagePromptButtonProps = {
  state: CreatePagePromptHookResult;
};

export const CreatePagePromptButton = ({ state }: CreatePagePromptButtonProps) => (
  <div className="flex items-center gap-3">
    <Button onClick={() => void state.customize()} disabled={state.creating}>
      {state.creating ? "Opening…" : state.existingPageSlug ? "Edit page" : "Customize page"}
    </Button>
    {state.error ? <span className="text-sm text-destructive">{state.error}</span> : null}
  </div>
);
