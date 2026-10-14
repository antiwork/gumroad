import { EditorContent } from "@tiptap/react";
import * as React from "react";

import type { PublicFile } from "$app/components/Product";
import { useRichTextEditor } from "$app/components/RichTextEditor";
import { PublicFileEmbed, PublicFilesSettingsContext } from "$app/components/TiptapExtensions/PublicFileEmbed";
import { ReviewCard } from "$app/components/TiptapExtensions/ReviewCard";
import { UpsellCard } from "$app/components/TiptapExtensions/UpsellCard";
import { useRunOnce } from "$app/components/useRunOnce";

export const Description = ({
  html,
  publicFiles,
  fallback,
}: {
  html: string | null;
  publicFiles: PublicFile[];
  fallback: React.ReactNode;
}) => {
  const [mounted, setMounted] = React.useState(false);
  // Created empty and filled after mount: the editor's content reset parses HTML without
  // `preserveWhitespace`, which is how descriptions have always rendered.
  const editor = useRichTextEditor({
    initialValue: mounted ? html : null,
    extensions: [UpsellCard, PublicFileEmbed, ReviewCard],
    editable: false,
  });
  useRunOnce(() => setMounted(true));
  const publicFilesSettings = React.useMemo(() => ({ files: publicFiles }), [publicFiles]);

  return mounted ? (
    <PublicFilesSettingsContext.Provider value={publicFilesSettings}>
      <EditorContent className="rich-text" dir="auto" editor={editor} />
    </PublicFilesSettingsContext.Provider>
  ) : (
    fallback
  );
};
