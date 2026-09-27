// happy-dom's Node.prototype.nodeName answers '' when DOMPurify calls the getter unapplied off the
// prototype (its clobbering defence), so from 3.4.12 sanitize() drops every wrapper element. #1810.
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
