// happy-dom keeps nodeName's implementations on the subclasses (Element, Text, Comment, Document,
// DocumentType) and leaves Node.prototype's getter returning ''. That is the getter DOMPurify reads:
// it lifts it off the prototype and calls it unapplied, so a clobbered own-property cannot lie to
// it. From 3.4.12 that read resolves every element to an unknown tag, and sanitize() then drops the
// element and hoists its children instead of sanitizing them. Upstream: capricorn86/happy-dom#1810.
//
// Import before anything that imports dompurify: dompurify captures the getter at module init.
Object.defineProperty(Node.prototype, "nodeName", {
  configurable: true,
  get(this: Node): string {
    if (this instanceof Element) return this.tagName;
    if (this instanceof Text) return "#text";
    if (this instanceof Comment) return "#comment";
    if (this instanceof Document) return "#document";
    if (this instanceof DocumentFragment) return "#document-fragment";
    return "";
  },
});
