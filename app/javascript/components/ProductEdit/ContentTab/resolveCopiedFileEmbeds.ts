import { ExistingFileEntry, FileEntry } from "$app/components/ProductEdit/state";

// File embeds copied from another product carry a `url` attribute (set by FileEmbed's
// `transformCopied` plugin) so we can map them onto this seller's files. However, ProseMirror
// also runs `transformCopied` when a node is DRAGGED (drag-and-drop reordering uses the same
// clipboard serialization), so file embeds that already belong to this product can arrive here
// with a `url` attribute too. Those must be kept as-is: matching them against `existingFiles`
// (a limited snapshot fetched at page load) would silently DELETE embeds for files uploaded
// during the current editing session, because they aren't in that snapshot. That caused sellers'
// existing files to vanish on save after reordering content (gumroad-private#1164).
export const resolveCopiedFileEmbeds = (
  fragment: { querySelectorAll: (selector: string) => Iterable<Element> },
  filesById: Map<string, FileEntry>,
  existingFiles: ExistingFileEntry[],
): ExistingFileEntry[] => {
  const newFiles: ExistingFileEntry[] = [];
  for (const node of fragment.querySelectorAll("file-embed[url]")) {
    const id = node.getAttribute("id");
    // Already one of this product's files (e.g. the embed was dragged, not pasted from
    // another product) — just drop the transient `url` marker and leave the embed alone.
    if (id && filesById.has(id)) {
      node.removeAttribute("url");
      continue;
    }
    const file = existingFiles.find((file) => file.id === id || file.url === node.getAttribute("url"));
    if (file) {
      node.setAttribute("id", file.id);
      if (!newFiles.includes(file)) newFiles.push(file);
      node.removeAttribute("url");
    } else {
      node.remove();
    }
  }
  return newFiles;
};
