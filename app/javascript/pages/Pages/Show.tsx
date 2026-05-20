import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

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
  const { page } = typia.assert<PageProps>(usePage().props);

  React.useEffect(() => {
    // Load Tailwind CDN for rendering
    const script = document.createElement("script");
    script.src = "https://cdn.tailwindcss.com";
    document.head.appendChild(script);
    return () => {
      document.head.removeChild(script);
    };
  }, []);

  return (
    <div className="min-h-screen">
      <div dangerouslySetInnerHTML={{ __html: page.html_content }} />
    </div>
  );
}
