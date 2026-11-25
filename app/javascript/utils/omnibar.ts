import { type OmnibarProduct, type OmnibarSale } from "$app/data/omnibar";

// Must match OmnibarSearchPresenter::MINIMUM_QUERY_LENGTH: the server answers nothing below it.
export const MINIMUM_SEARCH_LENGTH = 2;

// Counted in characters, as the server counts: "🎨" is one, though its JavaScript length is two.
export const isSearchable = (query: string) => Array.from(query.trim()).length >= MINIMUM_SEARCH_LENGTH;

export type OmnibarItemKind = "page" | "action" | "product" | "sale" | "search";
export type OmnibarItem = {
  id: string;
  kind: OmnibarItemKind;
  title: string;
  detail?: string;
  href: string;
  onSelect?: (() => void) | undefined;
};
export type OmnibarGroup = { title: string; items: OmnibarItem[] };
// A place or an action the bar offers without asking the server. `onSelect` runs before the visit,
// for a destination whose nav link does more than navigate.
export type OmnibarShortcut = {
  key: string;
  title: string;
  href: string;
  keywords?: string;
  onSelect?: (() => void) | undefined;
};
// Each group: undefined while its request is out, null when it failed.
export type OmnibarResults = {
  products?: OmnibarProduct[] | null | undefined;
  sales?: OmnibarSale[] | null | undefined;
};

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
    .map(({ key, title, href, onSelect }) => ({ id: `${kind}:${key}`, kind, title, href, onSelect }));

/**
 * The bar's rows, in the order they are shown. A row only ever appears below the rows already on
 * screen, so nothing moves under the pointer and the top row stays the top row: sales wait for
 * products, and the "Search … for" rows wait for both.
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
  results: OmnibarResults;
  searchLinks: { sales: (query: string) => string; products: (query: string) => string };
}): OmnibarGroup[] => {
  const trimmed = query.trim();
  const groups: OmnibarGroup[] = [
    { title: "Go to", items: shortcutItems("page", pages, trimmed) },
    { title: "Quick actions", items: shortcutItems("action", actions, trimmed) },
  ];
  const productsSettled = results.products !== undefined;
  const settled = productsSettled && results.sales !== undefined;

  if (isSearchable(query)) {
    groups.push({
      title: "Products",
      items: (results.products ?? []).map(({ id, name, url }) => ({
        id: `product:${id}`,
        kind: "product",
        title: name,
        href: url,
      })),
    });
    if (productsSettled) {
      groups.push({
        title: "Sales",
        items: (results.sales ?? []).map(({ id, email, name, product_name, url }) => ({
          id: `sale:${id}`,
          kind: "sale",
          title: name || email,
          detail: name ? `${email} · ${product_name}` : product_name,
          href: url,
        })),
      });
    }
    if (settled) {
      groups.push({
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
      });
    }
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
