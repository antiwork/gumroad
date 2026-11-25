import { ArchiveAlt, ArrowRight, Plus, Search as SearchIcon, User as UserIcon, X } from "@boxicons/react";
import { router } from "@inertiajs/react";
import * as Dialog from "@radix-ui/react-dialog";
import * as React from "react";

import { searchOmnibar, type OmnibarSearchResults } from "$app/data/omnibar";
import { classNames } from "$app/utils/classNames";
import {
  buildOmnibarGroups,
  MINIMUM_SEARCH_LENGTH,
  moveActiveId,
  nextActiveId,
  type OmnibarItem,
  type OmnibarItemKind,
  type OmnibarShortcut,
} from "$app/utils/omnibar";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { normalizeSearchQuery } from "$app/components/Search";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";

const SEARCH_DELAY_MS = 250;

// The layouts add this class from the request's user agent, so it is right on the first render.
const isMac = () => typeof document !== "undefined" && document.body.classList.contains("mac");

export const useOmnibar = () => {
  const [open, setOpen] = React.useState(false);

  React.useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key.toLowerCase() !== "k" || event.altKey || event.shiftKey) return;
      // Ctrl+K on a Mac deletes to the end of the line in every text field, so only ⌘K opens there.
      if (isMac() ? !event.metaKey || event.ctrlKey : !event.ctrlKey || event.metaKey) return;
      event.preventDefault();
      setOpen(true);
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, []);

  return React.useMemo(() => ({ open, show: () => setOpen(true), hide: () => setOpen(false) }), [open]);
};

const focusRing = "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-current";

/** "sidebar" is the field under the logo on wide screens; "bar" is the icon in the phone header. */
export const OmnibarTrigger = ({ variant, onOpen }: { variant: "sidebar" | "bar"; onOpen: () => void }) => {
  const [shortcut, setShortcut] = React.useState<{ label: string; keys: string } | null>(null);
  React.useEffect(
    () => setShortcut(isMac() ? { label: "⌘K", keys: "Meta+K" } : { label: "Ctrl K", keys: "Control+K" }),
    [],
  );

  if (variant === "bar") {
    return (
      <button
        type="button"
        className={classNames("cursor-pointer rounded all-unset", focusRing)}
        aria-label="Search"
        aria-haspopup="dialog"
        onClick={onOpen}
      >
        <SearchIcon className="size-5" />
      </button>
    );
  }

  return (
    <button
      type="button"
      // box-border: `all-unset` resets box-sizing, and the border would widen the field past the sidebar.
      className={classNames(
        "mx-6 mb-6 box-border hidden cursor-pointer items-center gap-2 rounded border border-white/50 px-3 py-2 text-left all-unset hover:border-white lg:flex dark:border-foreground/50 dark:hover:border-foreground",
        focusRing,
      )}
      aria-haspopup="dialog"
      aria-keyshortcuts={shortcut?.keys}
      onClick={onOpen}
    >
      <SearchIcon className="size-5 shrink-0" aria-hidden />
      <span className="flex-1">Search</span>
      {shortcut ? (
        <kbd className="font-[inherit] text-sm opacity-70" aria-hidden>
          {shortcut.label}
        </kbd>
      ) : null}
    </button>
  );
};

const KindIcon = ({ kind }: { kind: OmnibarItemKind }) => {
  const Icon = { page: ArrowRight, action: Plus, product: ArchiveAlt, customer: UserIcon, search: SearchIcon }[kind];
  return <Icon className="size-5 shrink-0 text-muted" aria-hidden />;
};

const isSameOrigin = (href: string) => new URL(href, window.location.href).origin === window.location.origin;

const visit = (href: string, newTab: boolean) => {
  if (newTab) window.open(href, "_blank", "noopener");
  else if (isSameOrigin(href)) router.visit(href);
  else window.location.assign(href);
};

type SearchResponse = { query: string; results: OmnibarSearchResults | null };

export const OmnibarDialog = ({
  open: isOpen,
  onClose,
  pages,
  actions,
}: {
  open: boolean;
  onClose: () => void;
  pages: OmnibarShortcut[];
  actions: OmnibarShortcut[];
}) => {
  const [query, setQuery] = React.useState("");
  const [response, setResponse] = React.useState<SearchResponse | null>(null);
  const [activeId, setActiveId] = React.useState<string | null>(null);
  const uid = React.useId();
  const listId = `${uid}-list`;
  const optionId = (id: string) => `${uid}-${id}`;

  React.useEffect(() => {
    if (!isOpen) return;
    setQuery("");
    setResponse(null);
    setActiveId(null);
  }, [isOpen]);

  const trimmed = query.trim();
  const searchable = trimmed.length >= MINIMUM_SEARCH_LENGTH;
  // A response for an earlier query says nothing about this one.
  const current = response?.query === trimmed ? response : null;
  const searching = searchable && !current;

  React.useEffect(() => {
    if (!isOpen || !searchable) return;
    const controller = new AbortController();
    const settle = (results: OmnibarSearchResults | null) => {
      if (!controller.signal.aborted) setResponse({ query: trimmed, results });
    };
    const timeout = window.setTimeout(() => {
      void searchOmnibar(trimmed, controller.signal).then(settle, () => settle(null));
    }, SEARCH_DELAY_MS);
    return () => {
      window.clearTimeout(timeout);
      controller.abort();
    };
  }, [isOpen, searchable, trimmed]);

  const groups = React.useMemo(
    () =>
      buildOmnibarGroups({
        query,
        pages,
        actions,
        results: current?.results ?? null,
        searchLinks: {
          sales: (value) => Routes.customers_path({ query: value }),
          products: (value) => Routes.products_path({ query: value }),
        },
      }),
    [query, pages, actions, current],
  );
  const items = groups.flatMap((group) => group.items);
  const activeItemId = nextActiveId(items, activeId);

  React.useEffect(() => {
    if (activeItemId) document.getElementById(optionId(activeItemId))?.scrollIntoView({ block: "nearest" });
  }, [activeItemId]);

  const found = (current?.results?.products.length ?? 0) + (current?.results?.customers.length ?? 0);
  const note = !searchable
    ? items.length === 0
      ? "Keep typing to search your products and sales."
      : null
    : searching
      ? null
      : !current?.results
        ? "Couldn't search your products and sales. You can still jump to a page."
        : current.results.customers_unavailable
          ? "Sales can't be searched right now. Products and pages still can."
          : found === 0
            ? `No products or sales match “${trimmed}”.`
            : null;

  const select = (item: OmnibarItem, newTab = false) => {
    if (!newTab) onClose();
    visit(item.href, newTab);
  };

  return (
    <Dialog.Root open={isOpen} onOpenChange={(next) => (next ? undefined : onClose())}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-backdrop" />
        <Dialog.Content
          aria-describedby={undefined}
          className="fixed inset-x-0 top-0 z-51 mx-auto flex max-h-dvh w-full flex-col bg-background text-foreground shadow-lg sm:top-[10vh] sm:max-h-[70vh] sm:max-w-xl sm:rounded sm:border sm:border-border"
        >
          <Dialog.Title className="sr-only">Search</Dialog.Title>
          <div className="flex items-center gap-2 border-b border-border p-2">
            <InputGroup className="-outline-offset-2">
              {searching ? (
                <LoadingSpinner className="size-5" aria-label="Searching" />
              ) : (
                <SearchIcon className="size-5 shrink-0 text-muted" aria-hidden />
              )}
              <Input
                type="text"
                role="combobox"
                aria-label="Search products, sales and pages"
                aria-expanded
                aria-controls={listId}
                aria-autocomplete="list"
                aria-activedescendant={activeItemId ? optionId(activeItemId) : undefined}
                autoComplete="off"
                placeholder="Search products, sales and pages"
                value={query}
                onChange={(event) => setQuery(normalizeSearchQuery(event.target.value))}
                onKeyDown={(event) => {
                  // Enter and the arrows belong to an input method while it is composing.
                  if (event.nativeEvent.isComposing) return;
                  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                    event.preventDefault();
                    setActiveId(moveActiveId(items, activeItemId, event.key === "ArrowDown" ? 1 : -1));
                  } else if (event.key === "Enter") {
                    const item = items.find(({ id }) => id === activeItemId);
                    if (!item) return;
                    event.preventDefault();
                    select(item, event.metaKey || event.ctrlKey);
                  }
                }}
              />
            </InputGroup>
            <Dialog.Close className={classNames("cursor-pointer rounded p-2 all-unset", focusRing)} aria-label="Close">
              <X className="size-5" />
            </Dialog.Close>
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto p-2">
            <div id={listId} role="listbox" aria-label="Results">
              {groups.map((group, index) => {
                const headingId = `${uid}-group-${index}`;
                return (
                  <div key={group.title} role="group" aria-labelledby={headingId} className="grid">
                    <div id={headingId} role="presentation" className="px-3 pt-3 pb-1 text-sm text-muted">
                      {group.title}
                    </div>
                    {group.items.map((item) => {
                      const active = item.id === activeItemId;
                      return (
                        <a
                          key={item.id}
                          id={optionId(item.id)}
                          role="option"
                          aria-selected={active}
                          // Focus stays in the field; the rows are reached with the arrow keys.
                          tabIndex={-1}
                          href={item.href}
                          onClick={(event) => {
                            // A modified or middle click is the browser's own "open in a new tab".
                            if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
                            event.preventDefault();
                            select(item);
                          }}
                          onMouseMove={() => setActiveId(item.id)}
                          className={classNames(
                            "flex items-center gap-3 rounded px-3 py-2 no-underline",
                            // The bar marks the row without relying on the tint's 1.2:1 against the surface.
                            active && "bg-active-bg shadow-[inset_0.25rem_0_0_var(--color-foreground)]",
                          )}
                        >
                          <KindIcon kind={item.kind} />
                          <span className="min-w-0 flex-1 truncate">{item.title}</span>
                          {item.detail ? (
                            <span className="max-w-1/2 min-w-0 truncate text-sm text-muted">{item.detail}</span>
                          ) : null}
                        </a>
                      );
                    })}
                  </div>
                );
              })}
            </div>
            {/* One live region: a note is shown, a bare result count is only announced. */}
            <p role="status" className={note ? "px-3 py-3 text-sm text-muted" : "sr-only"}>
              {searching ? "Searching" : (note ?? `${items.length} ${items.length === 1 ? "result" : "results"}`)}
            </p>
          </div>
          <div aria-hidden className="hidden gap-4 border-t border-border px-4 py-2 text-sm text-muted sm:flex">
            <span>↑↓ to move</span>
            <span>↵ to open</span>
            <span>esc to close</span>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
};
