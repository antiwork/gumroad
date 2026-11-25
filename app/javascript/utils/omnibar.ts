import { type OmnibarSearchResults } from "$app/data/omnibar";

// Must match OmnibarSearchPresenter::MINIMUM_QUERY_LENGTH: the server answers nothing below it.
export const MINIMUM_SEARCH_LENGTH = 2;

export type OmnibarItemKind = "page" | "action" | "product" | "customer" | "search";
export type OmnibarItem = { id: string; kind: OmnibarItemKind; title: string; detail?: string; href: string };
export type OmnibarGroup = { title: string; items: OmnibarItem[] };
// A place or an action the bar offers without asking the server.
export type OmnibarShortcut = { key: string; title: string; href: string; keywords?: string };

const normalize = (text: string) => text.normalize("NFKC").toLowerCase();

/** True when every word of the query appears somewhere in the values. An empty query matches. */
export const matchesQuery = (query: string, ...values: (string | null | undefined)[]) => {
  const text = normalize(values.filter(Boolean).join(" "));
  return normalize(query)
    .split(/\s+/u)
    .filter(Boolean)
    .every((term) => text.includes(term));
};

const shortcutItems = (kind: "page" | "action", shortcuts: OmnibarShortcut[], query: string): OmnibarItem[] =>
  shortcuts
    .filter((shortcut) => matchesQuery(query, shortcut.title, shortcut.keywords))
    .map(({ key, title, href }) => ({ id: `${kind}:${key}`, kind, title, href }));

/**
 * The bar's rows, in the order they are shown. Places and actions come first because they are
 * known at once: results that arrive later are added below them and never push a row the seller
 * is about to open.
 */
export const buildOmnibarGroups = ({
  query,
  pages,
  actions,
  results,
  searchLinks,
}: {
  query: string;
  pages: OmnibarShortcut[];
  actions: OmnibarShortcut[];
  results: OmnibarSearchResults | null;
  searchLinks: { sales: (query: string) => string; products: (query: string) => string };
}): OmnibarGroup[] => {
  const trimmed = query.trim();
  const groups: OmnibarGroup[] = [
    { title: "Go to", items: shortcutItems("page", pages, trimmed) },
    { title: "Quick actions", items: shortcutItems("action", actions, trimmed) },
  ];

  if (trimmed.length >= MINIMUM_SEARCH_LENGTH) {
    groups.push(
      {
        title: "Products",
        items: (results?.products ?? []).map(({ id, name, url }) => ({
          id: `product:${id}`,
          kind: "product",
          title: name,
          href: url,
        })),
      },
      {
        title: "Sales",
        items: (results?.customers ?? []).map(({ id, email, name, product_name, url }) => ({
          id: `customer:${id}`,
          kind: "customer",
          title: name || email,
          detail: name ? `${email} · ${product_name}` : product_name,
          href: url,
        })),
      },
      {
        title: "Search",
        items: [
          {
            id: "search:sales",
            kind: "search",
            title: `Search sales for “${trimmed}”`,
            href: searchLinks.sales(trimmed),
          },
          {
            id: "search:products",
            kind: "search",
            title: `Search products for “${trimmed}”`,
            href: searchLinks.products(trimmed),
          },
        ],
      },
    );
  }

  return groups.filter((group) => group.items.length > 0);
};

/** The row that stays active when the rows change: the same one if it is still there, else the first. */
export const nextActiveId = (items: OmnibarItem[], activeId: string | null) =>
  items.some((item) => item.id === activeId) ? activeId : (items[0]?.id ?? null);

/** The row `step` away from the active one, wrapping at both ends. */
export const moveActiveId = (items: OmnibarItem[], activeId: string | null, step: 1 | -1) => {
  if (items.length === 0) return null;
  const index = items.findIndex((item) => item.id === activeId);
  if (index === -1) return (step === 1 ? items[0] : items[items.length - 1])?.id ?? null;
  return items[(index + step + items.length) % items.length]?.id ?? null;
};
