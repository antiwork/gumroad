import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { showAlert } from "$app/components/server-components/Alert";
import { Input } from "$app/components/ui/Input";
import { PageHeader } from "$app/components/ui/PageHeader";
import { assertResponseError, request } from "$app/utils/request";

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
  product: ProductOption | null;
};

type PageProps = {
  page: PageData;
  products: ProductOption[];
  versions: VersionInfo[];
};

type ChatMessage = {
  role: "user" | "assistant";
  content: string;
};

export default function PageEdit() {
  const { page: initialPage, products, versions } = typia.assert<PageProps>(usePage().props);
  const currentSeller = useCurrentSeller();
  const iframeRef = React.useRef<HTMLIFrameElement>(null);

  const [page, setPage] = React.useState(initialPage);
  const [prompt, setPrompt] = React.useState("");
  const [generating, setGenerating] = React.useState(false);
  const [saving, setSaving] = React.useState(false);
  const [publishing, setPublishing] = React.useState(false);
  const [chatHistory, setChatHistory] = React.useState<ChatMessage[]>(
    versions.map((v) => ({ role: "user" as const, content: v.prompt })).reverse(),
  );

  const chatEndRef = React.useRef<HTMLDivElement>(null);

  React.useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [chatHistory]);

  // Update iframe content when HTML changes
  React.useEffect(() => {
    if (!iframeRef.current || !page.html_content) return;
    const doc = iframeRef.current.contentDocument;
    if (!doc) return;
    doc.open();
    doc.write(`
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://cdn.tailwindcss.com"><\/script>
      </head>
      <body>
        ${page.html_content}
      </body>
      </html>
    `);
    doc.close();
  }, [page.html_content]);

  const generate = async () => {
    if (!prompt.trim() || generating) return;
    const userPrompt = prompt.trim();
    setPrompt("");
    setGenerating(true);
    setChatHistory((prev) => [...prev, { role: "user", content: userPrompt }]);

    try {
      const response = await request({
        method: "POST",
        url: Routes.generate_page_path(page.slug),
        accept: "json",
        data: { prompt: userPrompt },
      });
      const result = typia.assert<{ success: boolean; html: string; version_id: number }>(
        await response.json(),
      );
      setPage((prev) => ({ ...prev, html_content: result.html }));
      setChatHistory((prev) => [...prev, { role: "assistant", content: "Page updated! Check the preview." }]);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message || "Failed to generate. Try again.", "error");
      setChatHistory((prev) => [...prev, { role: "assistant", content: "Failed to generate. Please try again." }]);
    } finally {
      setGenerating(false);
    }
  };

  const save = async () => {
    setSaving(true);
    try {
      await request({
        method: "PUT",
        url: Routes.update_page_path(page.slug),
        accept: "json",
        data: { page: { title: page.title, html_content: page.html_content } },
      });
      showAlert("Saved!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setSaving(false);
    }
  };

  const togglePublish = async () => {
    setPublishing(true);
    try {
      const url = page.published
        ? Routes.unpublish_page_path(page.slug)
        : Routes.publish_page_path(page.slug);
      await request({ method: "POST", url, accept: "json" });
      const newPublished = !page.published;
      setPage((prev) => ({ ...prev, published: newPublished }));
      showAlert(newPublished ? "Published!" : "Unpublished!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setPublishing(false);
    }
  };

  const pageUrl = currentSeller
    ? `${window.location.origin}/${currentSeller.subdomain}/pages/${page.slug}`
    : "";

  const isBusy = generating || saving || publishing;

  return (
    <>
      <PageHeader
        className="sticky-top"
        title={page.title || "Untitled page"}
        actions={
          <>
            {page.published ? (
              <>
                <Button disabled={isBusy} onClick={() => void togglePublish()}>
                  {publishing ? "Unpublishing..." : "Unpublish"}
                </Button>
                <Button color="primary" disabled={isBusy} onClick={() => void save()}>
                  {saving ? "Saving..." : "Save"}
                </Button>
                <CopyToClipboard text={pageUrl} copyTooltip="Copy page URL">
                  <Button>Copy URL</Button>
                </CopyToClipboard>
              </>
            ) : (
              <>
                <Button color="primary" disabled={isBusy} onClick={() => void save()}>
                  {saving ? "Saving..." : "Save"}
                </Button>
                <Button
                  color="accent"
                  disabled={isBusy || !page.html_content}
                  onClick={() => void togglePublish()}
                >
                  {publishing ? "Publishing..." : "Publish"}
                </Button>
              </>
            )}
          </>
        }
      />
      <div className="flex flex-1" style={{ height: "calc(100vh - 120px)" }}>
        {/* Chat Panel */}
        <div className="flex w-96 shrink-0 flex-col border-r border-border">
          <div className="flex-1 overflow-y-auto p-4">
            {chatHistory.length === 0 ? (
              <div className="flex h-full flex-col items-center justify-center gap-4 text-center text-muted">
                <p className="text-lg font-medium">Describe your landing page</p>
                <p className="text-sm">
                  Tell the AI what you want and it'll build it. You can iterate with follow-up messages.
                </p>
                <div className="flex flex-col gap-2">
                  {[
                    "A sleek dark landing page for my course",
                    "A minimalist product showcase with pricing cards",
                    "A long-form sales letter optimized for conversions",
                  ].map((suggestion) => (
                    <button
                      key={suggestion}
                      type="button"
                      className="rounded-full border border-border px-3 py-1.5 text-left text-sm transition-colors hover:bg-active-bg"
                      onClick={() => setPrompt(suggestion)}
                    >
                      {suggestion}
                    </button>
                  ))}
                </div>
              </div>
            ) : (
              <div className="flex flex-col gap-3">
                {chatHistory.map((msg, i) => (
                  <div
                    key={i}
                    className={`rounded-lg px-3 py-2 text-sm ${
                      msg.role === "user"
                        ? "ml-8 self-end bg-accent text-accent-foreground"
                        : "mr-8 self-start bg-active-bg"
                    }`}
                  >
                    {msg.content}
                  </div>
                ))}
                {generating ? (
                  <div className="mr-8 self-start rounded-lg bg-active-bg px-3 py-2 text-sm">
                    <span className="animate-pulse">Generating...</span>
                  </div>
                ) : null}
                <div ref={chatEndRef} />
              </div>
            )}
          </div>
          <form
            className="border-t border-border p-4"
            onSubmit={(e) => {
              e.preventDefault();
              void generate();
            }}
          >
            <div className="flex gap-2">
              <Input
                value={prompt}
                onChange={(e) => setPrompt(e.target.value)}
                placeholder={page.html_content ? "Describe changes..." : "Describe your page..."}
                disabled={generating}
                autoFocus
              />
              <Button type="submit" color="primary" disabled={!prompt.trim() || generating}>
                {generating ? "..." : "Send"}
              </Button>
            </div>
          </form>
        </div>

        {/* Preview Panel */}
        <div className="flex-1 bg-gray-50">
          {page.html_content ? (
            <iframe
              ref={iframeRef}
              className="h-full w-full border-0"
              title="Page preview"
              sandbox="allow-scripts"
            />
          ) : (
            <div className="flex h-full items-center justify-center text-muted">
              <p>Send a message to generate your page</p>
            </div>
          )}
        </div>
      </div>
    </>
  );
}
