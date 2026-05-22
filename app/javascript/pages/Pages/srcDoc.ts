/*
 * Builds the iframe srcDoc HTML used by Pages views (Edit preview, public Show).
 * Loads the pre-built kitchen-sink Tailwind CSS from /pages-tailwind.css so the
 * iframe never has to compile classes at render time.
 */
export const buildSrcDoc = (
  htmlContent: string,
  options: { openLinksInNewTab?: boolean; bodyReset?: boolean } = {},
): string => {
  const baseTag = options.openLinksInNewTab ? '<base target="_blank">' : "";
  const resetStyle = options.bodyReset ? "<style>html, body { margin: 0; padding: 0; min-height: 100vh; }</style>" : "";
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">${baseTag}<link rel="stylesheet" href="/pages-tailwind.css">${resetStyle}</head><body>${htmlContent}</body></html>`;
};
