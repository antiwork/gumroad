import StarterKit from "@tiptap/starter-kit";

const extension = StarterKit.extend();
// eslint-disable-next-line @typescript-eslint/no-unnecessary-condition -- Tiptap types are incorrect
extension.options = new Proxy(extension.options ?? {}, {
  get: (_, prop) => typeof prop === "string" && ["document", "text", "paragraph"].includes(prop),
});
export default extension;
