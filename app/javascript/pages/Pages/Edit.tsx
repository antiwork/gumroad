import { Head, usePage } from "@inertiajs/react";
import * as React from "react";

import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { Input } from "$app/components/ui/Input";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Switch } from "$app/components/ui/Switch";

import { buildSrcDoc } from "./srcDoc";

type ProductOption = {
  id: string;
  name: string;
  permalink: string;
  price: string;
  thumbnail_url: string | null;
  short_url: string;
};

type VersionInfo = {
  id: number;
  prompt: string;
  created_at: string;
};

type PageData = {
  id: string;
  title: string;
  slug: string;
  html_content: string | null;
  published: boolean;
  published_at: string | null;
  published_version_id: number | null;
  auto_publish: boolean;
  is_profile: boolean;
  generating: boolean;
  generation_error: string | null;
  product: ProductOption | null;
  page_url: string;
};

type TemplateSummary = {
  id: string;
  name: string;
  description: string;
  icon: string;
};

type PageProps = {
  page: PageData;
  products: ProductOption[];
  versions: VersionInfo[];
  templates: TemplateSummary[];
};

type LatestVersionResponse = {
  html_content: string | null;
  latest_version: VersionInfo | null;
  published_version_id: number | null;
  published: boolean;
  auto_publish: boolean;
  generating: boolean;
  generation_error: string | null;
};

type PublishResponse = {
  success: boolean;
  published_version_id: number | null;
  error?: string;
};

const POLL_INTERVAL_MS = 3000;

const CoinShower = () => {
  const coins = React.useMemo(
    () =>
      Array.from({ length: 24 }, (_, i) => ({
        id: i,
        left: Math.random() * 100,
        delay: Math.random() * 4,
        duration: 3 + Math.random() * 3,
        size: 24 + Math.random() * 24,
      })),
    [],
  );
  return (
    <div className="pointer-events-none absolute inset-0 overflow-hidden" aria-hidden="true">
      <style>{`
        @keyframes coin-fall {
          0% { transform: translate3d(0, -10vh, 0) rotate(0deg); opacity: 0; }
          10% { opacity: 1; }
          100% { transform: translate3d(0, 110vh, 0) rotate(540deg); opacity: 0.8; }
        }
      `}</style>
      {coins.map((c) => (
        <div
          key={c.id}
          className="absolute top-0"
          style={{
            left: `${c.left}%`,
            width: c.size,
            height: c.size,
            animation: `coin-fall ${c.duration}s linear ${c.delay}s infinite`,
          }}
        >
          <div
            className="size-full rounded-full"
            style={{
              background: "radial-gradient(circle at 35% 30%, #fef3c7 0%, #fbbf24 45%, #b45309 100%)",
              boxShadow: "inset -2px -3px 4px rgba(0,0,0,0.25), 0 2px 6px rgba(0,0,0,0.15)",
            }}
          />
        </div>
      ))}
    </div>
  );
};

const GeneratingPlaceholder = ({ message }: { message: string }) => (
  <div className="relative flex h-full w-full items-center justify-center bg-gradient-to-b from-amber-50 to-amber-100">
    <CoinShower />
    <div className="relative z-1 flex flex-col items-center gap-3 text-center">
      <p className="text-lg font-bold">{message}</p>
      <p className="text-sm text-muted">This can take a minute — feel free to keep iterating in chat.</p>
    </div>
  </div>
);

export default function PageEdit() {
  const { page: initialPage, versions: initialVersions, templates } = usePage<PageProps>().props;
  const [page, setPage] = React.useState(initialPage);
  const [versions, setVersions] = React.useState(initialVersions);
  const [prompt, setPrompt] = React.useState("");
  const [generating, setGenerating] = React.useState(initialPage.generating);
  const [publishing, setPublishing] = React.useState(false);
  const [titleDraft, setTitleDraft] = React.useState(initialPage.title);
  const [previewLoaded, setPreviewLoaded] = React.useState(false);

  // Surface three random starter prompts on first load so creators aren't
  // staring at a blank "describe your vibe" box. Picked once per mount so
  // the chips don't reshuffle as the user types — `useMemo` over a stable
  // input is intentional.
  const suggestedTemplates = React.useMemo<TemplateSummary[]>(() => {
    if (!templates || templates.length === 0) return [];
    const pool = [...templates];
    for (let i = pool.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [pool[i], pool[j]] = [pool[j]!, pool[i]!];
    }
    return pool.slice(0, 3);
  }, [templates]);

  // Re-fade the preview iframe whenever a new generation arrives.
  React.useEffect(() => {
    setPreviewLoaded(false);
  }, [page.html_content]);

  // Initial generation may still be running (kicked off async from New)
  const [waitingForFirst, setWaitingForFirst] = React.useState(
    initialPage.html_content == null || initialPage.html_content === "",
  );

  // Poll for the latest version while we are waiting on async generation.
  React.useEffect(() => {
    if (!waitingForFirst && !generating) return;
    let cancelled = false;

    const tick = async () => {
      try {
        const resp = await fetch(Routes.latest_version_page_path(page.slug), {
          headers: { Accept: "application/json" },
          credentials: "same-origin",
        });
        if (!resp.ok) return;
        const body: LatestVersionResponse = await resp.json();
        if (cancelled) return;

        if (body.html_content && body.html_content !== page.html_content) {
          setPage((prev) => ({
            ...prev,
            html_content: body.html_content,
            published_version_id: body.published_version_id,
            published: body.published,
            auto_publish: body.auto_publish,
          }));
          if (body.latest_version) {
            const real = body.latest_version;
            // Drop optimistic placeholders (negative ids) and any stale entry with
            // the same real id, then insert the real version at the top.
            setVersions((prev) => [real, ...prev.filter((v) => v.id > 0 && v.id !== real.id)]);
          }
          setGenerating(false);
          setWaitingForFirst(false);
        } else if (!body.generating) {
          // Generation job finished without producing content (AI error or
          // moderation rejection). Stop polling and let the user retry.
          setGenerating(false);
          setWaitingForFirst(false);
          if (body.generation_error) {
            showAlert(body.generation_error, "error");
          }
        }
      } catch {
        // network blip — keep polling
      }
    };

    const interval = setInterval(() => void tick(), POLL_INTERVAL_MS);
    void tick();
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [waitingForFirst, generating, page.slug, page.html_content]);

  const sendPrompt = async () => {
    if (!prompt.trim() || generating) return;
    const userPrompt = prompt.trim();
    const optimisticId = -Date.now();
    setPrompt("");
    setGenerating(true);
    setVersions((prev) => [{ id: optimisticId, prompt: userPrompt, created_at: new Date().toISOString() }, ...prev]);

    try {
      await request({
        method: "POST",
        url: Routes.generate_page_path(page.slug),
        accept: "json",
        data: { prompt: userPrompt },
      });
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message || "Failed to generate. Try again.", "error");
      setVersions((prev) => prev.filter((v) => v.id !== optimisticId));
      setGenerating(false);
    }
  };

  const saveTitle = async (next: string) => {
    if (next === page.title) return;
    try {
      await request({
        method: "PUT",
        url: Routes.update_page_path(page.slug),
        accept: "json",
        data: { page: { title: next } },
      });
      setPage((prev) => ({ ...prev, title: next }));
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  const publishVersion = async (versionId?: number) => {
    setPublishing(true);
    try {
      const resp = await request({
        method: "POST",
        url: Routes.publish_page_path(page.slug),
        accept: "json",
        data: versionId ? { version_id: versionId } : {},
      });
      const body: PublishResponse = await resp.json();
      if (!body.success) {
        showAlert(body.error || "Failed to publish.", "error");
        return;
      }
      setPage((prev) => ({ ...prev, published: true, published_version_id: body.published_version_id }));
      showAlert("Published!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setPublishing(false);
    }
  };

  const unpublish = async () => {
    setPublishing(true);
    try {
      await request({
        method: "POST",
        url: Routes.unpublish_page_path(page.slug),
        accept: "json",
      });
      setPage((prev) => ({ ...prev, published: false }));
      showAlert("Unpublished!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setPublishing(false);
    }
  };

  const toggleAutoPublish = async (next: boolean) => {
    try {
      await request({
        method: "PUT",
        url: Routes.update_page_path(page.slug),
        accept: "json",
        data: { page: { auto_publish: next } },
      });
      setPage((prev) => ({ ...prev, auto_publish: next }));
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  // Backend computes page_url: subdomain URL when configured, falls back to
  // the username-scoped public route. Always non-empty so Copy URL works
  // for every seller.
  const pageUrl = page.page_url;

  return (
    <>
      <Head>
        <link rel="preload" href="/pages-tailwind.css" as="style" />
      </Head>
      <PageHeader
        className="sticky-top"
        title={
          <Input
            value={titleDraft}
            onChange={(e) => setTitleDraft(e.target.value)}
            onBlur={() => void saveTitle(titleDraft.trim() || "Untitled page")}
            className="w-72"
            aria-label="Page title"
          />
        }
        actions={
          <>
            {page.published ? (
              <CopyToClipboard text={pageUrl} copyTooltip="Copy page URL">
                <Button>Copy URL</Button>
              </CopyToClipboard>
            ) : null}
            <Popover>
              <PopoverAnchor>
                <PopoverTrigger asChild>
                  <Button color="accent" disabled={publishing}>
                    {publishing ? "Publishing..." : page.published ? "Published ▾" : "Publish ▾"}
                  </Button>
                </PopoverTrigger>
              </PopoverAnchor>
              <PopoverContent>
                <div className="flex w-72 flex-col gap-3">
                  <div className="flex items-center justify-between gap-3">
                    <Switch
                      checked={page.auto_publish}
                      onChange={(e) => void toggleAutoPublish(e.target.checked)}
                      label="Auto-publish the latest version"
                    />
                  </div>
                  {page.published ? (
                    <Button outline color="danger" onClick={() => void unpublish()}>
                      Unpublish
                    </Button>
                  ) : (
                    <Button color="primary" onClick={() => void publishVersion()}>
                      Publish latest version
                    </Button>
                  )}
                  {versions.some((v) => v.id > 0) ? (
                    <div className="flex flex-col gap-1">
                      <small className="text-muted">Or publish a previous version:</small>
                      <div className="max-h-64 overflow-y-auto">
                        {versions
                          .filter((v) => v.id > 0)
                          .map((v) => (
                            <button
                              key={v.id}
                              type="button"
                              onClick={() => void publishVersion(v.id)}
                              className={`flex w-full flex-col gap-0.5 rounded p-2 text-left transition-colors hover:bg-active-bg ${
                                v.id === page.published_version_id ? "bg-active-bg" : ""
                              }`}
                            >
                              <small className="font-medium">{new Date(v.created_at).toLocaleString()}</small>
                              <small className="line-clamp-2 text-muted">{v.prompt}</small>
                            </button>
                          ))}
                      </div>
                    </div>
                  ) : null}
                </div>
              </PopoverContent>
            </Popover>
          </>
        }
      />
      <div className="flex flex-1" style={{ height: "calc(100vh - 120px)" }}>
        {/* Chat Panel */}
        <div className="flex w-96 shrink-0 flex-col border-r border-border">
          <div className="flex-1 overflow-y-auto p-4">
            {versions.length === 0 && !waitingForFirst ? (
              <div className="flex h-full flex-col items-center justify-center gap-4 text-center text-muted">
                <p className="text-lg font-medium">Describe your landing page</p>
                <p className="text-sm">
                  Describe what you want. You can refine it with follow-up messages.
                </p>
              </div>
            ) : (
              <div className="flex flex-col gap-3">
                {[...versions].reverse().map((v) => (
                  <div
                    key={v.id}
                    className="ml-8 self-end rounded-lg bg-accent px-3 py-2 text-sm text-accent-foreground"
                  >
                    {v.prompt}
                  </div>
                ))}
                {generating || waitingForFirst ? (
                  <div className="mr-8 self-start rounded-lg bg-active-bg px-3 py-2 text-sm">
                    <span className="animate-pulse">Generating...</span>
                  </div>
                ) : null}
              </div>
            )}
          </div>
          <form
            className="border-t border-border p-4"
            onSubmit={(e) => {
              e.preventDefault();
              void sendPrompt();
            }}
          >
            {versions.length === 0 && !generating && !waitingForFirst && suggestedTemplates.length > 0 ? (
              <div className="mb-3 flex flex-col gap-2">
                <small className="text-muted">Try one of these, or mix two (e.g. "zine × dive bar"):</small>
                <div className="flex flex-wrap gap-2">
                  {suggestedTemplates.map((t) => (
                    <button
                      key={t.id}
                      type="button"
                      onClick={() => setPrompt(t.name)}
                      className="rounded-full border border-border bg-background px-3 py-1 text-left text-xs transition-colors hover:bg-active-bg"
                      title={t.description}
                    >
                      {t.name}
                    </button>
                  ))}
                </div>
              </div>
            ) : null}
            <div className="flex gap-2">
              <Input
                value={prompt}
                onChange={(e) => setPrompt(e.target.value)}
                placeholder={page.html_content ? "Describe changes..." : "Describe your page..."}
                disabled={generating}
                autoFocus
              />
              <Button type="submit" color="primary" disabled={!prompt.trim() || generating || waitingForFirst}>
                {generating || waitingForFirst ? "..." : "Send"}
              </Button>
            </div>
          </form>
        </div>

        {/* Preview Panel */}
        <div className="relative flex-1 bg-gray-50">
          {page.html_content ? (
            <div className="h-full w-full bg-dark-gray">
              <iframe
                className={`h-full w-full border-0 transition-opacity duration-300 ${previewLoaded ? "opacity-100" : "opacity-0"}`}
                title="Page preview"
                sandbox="allow-scripts allow-popups"
                srcDoc={buildSrcDoc(page.html_content, { openLinksInNewTab: true })}
                onLoad={() => setPreviewLoaded(true)}
              />
            </div>
          ) : (
            <GeneratingPlaceholder message="Building your page" />
          )}
        </div>
      </div>
    </>
  );
}
