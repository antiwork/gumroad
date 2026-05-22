import { usePage } from "@inertiajs/react";
import * as React from "react";
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
  const iframeRef = React.useRef<HTMLIFrameElement>(null);

  React.useEffect(() => {
    const iframe = iframeRef.current;
    if (!iframe || !page.html_content) return;

    const doc = iframe.contentDocument;
    if (!doc) return;

    doc.open();
    doc.write(`
      <!DOCTYPE html>
      <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <script src="https://cdn.tailwindcss.com"><\/script>
          <style>
            html, body { margin: 0; padding: 0; min-height: 100vh; }
          </style>
        </head>
        <body>${page.html_content}</body>
      </html>
    `);
    doc.close();
  }, [page.html_content]);

  return (
    <div className="min-h-screen">
      <iframe
        ref={iframeRef}
        className="h-screen w-full border-0"
        title={page.title}
        sandbox="allow-scripts"
      />
    </div>
  );
}
