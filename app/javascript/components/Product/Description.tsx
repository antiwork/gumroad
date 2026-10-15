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
  // The editor applies that content in a microtask queued by its own effect, which runs before this
  // one, so this microtask lands after it. Until then the stored HTML stays: an editor shown empty
  // for a frame collapses the description and shifts the page below it.
  const [filled, setFilled] = React.useState(false);
  React.useEffect(() => {
    if (editor && mounted) queueMicrotask(() => setFilled(true));
  }, [editor, mounted]);
  const publicFilesSettings = React.useMemo(() => ({ files: publicFiles }), [publicFiles]);

  return filled ? (
    <PublicFilesSettingsContext.Provider value={publicFilesSettings}>
      <EditorContent className="rich-text" dir="auto" editor={editor} />
    </PublicFilesSettingsContext.Provider>
  ) : (
    fallback
  );
};
