import {
  ArchiveAlt,
  ArrowRight,
  MessageBubble,
  Microphone,
  Plus,
  Search as SearchIcon,
  User as UserIcon,
  X,
} from "@boxicons/react";
import { router } from "@inertiajs/react";
import * as Dialog from "@radix-ui/react-dialog";
import * as React from "react";

import { searchOmnibarProducts, searchOmnibarSales } from "$app/data/omnibar";
import { classNames } from "$app/utils/classNames";
import { isDictationSupported, useDictation } from "$app/utils/dictation";
import {
  buildOmnibarGroups,
  isSearchable,
  moveActiveId,
  nextActiveId,
  type OmnibarAgent,
  type OmnibarItem,
  type OmnibarItemKind,
  type OmnibarResults,
  type OmnibarShortcut,
} from "$app/utils/omnibar";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { type PageSearch } from "$app/components/PageSearch";
import { normalizeSearchQuery } from "$app/components/Search";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";

const SEARCH_DELAY_MS = 250;
// What a keydown reports while an input method is composing, in browsers that end the composition
// before the Enter that commits it.
const IME_KEY_CODE = 229;

// The layouts add this class from the request's user agent, so it is right on the first render.
const isMac = () => typeof document !== "undefined" && document.body.classList.contains("mac");

// Off a Mac, Ctrl does not switch a Cyrillic or Greek layout to Latin, so the K key reports its
// own letter. The physical key stands in then, and only then: on Dvorak the printed K still wins.
const isKKey = (event: KeyboardEvent) => {
  const key = typeof event.key === "string" ? event.key : "";
  return key.toLowerCase() === "k" || (event.code === "KeyK" && !/^[a-z]$/iu.test(key));
};

export const useOmnibar = () => {
  const [open, setOpen] = React.useState(false);
  // Opened from a microphone button: the bar starts listening as it opens.
  const [dictate, setDictate] = React.useState(false);

  React.useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!isKKey(event) || event.altKey || event.shiftKey) return;
      // Ctrl+K on a Mac deletes to the end of the line in every text field, so only ⌘K opens there.
      if (isMac() ? !event.metaKey || event.ctrlKey : !event.ctrlKey || event.metaKey) return;
      event.preventDefault();
      setDictate(false);
      setOpen(true);
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, []);

  return React.useMemo(
    () => ({
      open,
      dictate,
      show: (options?: { dictate?: boolean }) => {
        setDictate(options?.dictate === true);
        setOpen(true);
      },
      hide: () => setOpen(false),
    }),
    [open, dictate],
  );
};

const focusRing = "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-current";

/** "field" looks like a search field and is placed by `className`; "icon" is the phone header's button. */
export const OmnibarTrigger = ({
  variant,
  onOpen,
  className,
  canAsk = false,
  compact = false,
  microphone = true,
}: {
  variant: "field" | "icon";
  onOpen: (options?: { dictate?: boolean }) => void;
  className?: string;
  // With an assistant connected the bar takes questions too, and says so.
  canAsk?: boolean;
  // In the phone bar: no shortcut hint and no microphone, which the open bar has.
  compact?: boolean;
  // Off where the field is too narrow for the label beside it, as in the sidebar. The open bar has one.
  microphone?: boolean;
}) => {
  // Both are only known in the browser, so the first render matches the server's without them.
  const [shortcut, setShortcut] = React.useState<{ label: string; keys: string } | null>(null);
  const [canDictate, setCanDictate] = React.useState(false);
  React.useEffect(() => {
    // A touch-only device has no keyboard to press the shortcut on.
    const hasKeyboard = typeof window.matchMedia !== "function" || window.matchMedia("(any-hover: hover)").matches;
    setShortcut(
      !hasKeyboard ? null : isMac() ? { label: "⌘K", keys: "Meta+K" } : { label: "Ctrl+K", keys: "Control+K" },
    );
    setCanDictate(isDictationSupported());
  }, []);

  if (variant === "icon") {
    return (
      <button
        type="button"
        // The padding takes the target past 24px; the matching margin keeps the header's layout.
        className={classNames("-m-1 cursor-pointer rounded p-1 all-unset", focusRing, className)}
        aria-label="Search"
        aria-haspopup="dialog"
        onClick={() => onOpen()}
      >
        <SearchIcon className="size-5" />
      </button>
    );
  }

  return (
    // The field is two buttons in one border: the search, and the microphone where there is one.
    <div
      className={classNames(
        "box-border items-stretch rounded border border-white/50 hover:border-white dark:border-foreground/50 dark:hover:border-foreground",
        className,
      )}
    >
      <button
        type="button"
        className={classNames(
          "box-border flex min-w-0 flex-1 cursor-pointer items-center gap-2 rounded px-3 py-2 text-left all-unset",
          focusRing,
        )}
        aria-haspopup="dialog"
        aria-keyshortcuts={shortcut?.keys}
        onClick={() => onOpen()}
      >
        <SearchIcon className="size-5 shrink-0" aria-hidden />
        <span className="flex-1 truncate">{canAsk ? "Search or ask" : "Search"}</span>
        {shortcut && !compact ? (
          <kbd className="font-[inherit] text-sm whitespace-nowrap" aria-hidden>
            {shortcut.label}
          </kbd>
        ) : null}
      </button>
      {canDictate && microphone && !compact ? (
        <button
          type="button"
          className={classNames("box-border flex cursor-pointer items-center rounded px-3 all-unset", focusRing)}
          aria-label="Dictate"
          aria-haspopup="dialog"
          onClick={() => onOpen({ dictate: true })}
        >
          <Microphone className="size-5" aria-hidden />
        </button>
      ) : null}
    </div>
  );
};

const KindIcon = ({ kind }: { kind: OmnibarItemKind }) => {
  const Icon = {
    page: ArrowRight,
    action: Plus,
    product: ArchiveAlt,
    sale: UserIcon,
    search: SearchIcon,
    ask: MessageBubble,
  }[kind];
  return <Icon className="size-5 shrink-0 text-muted" aria-hidden />;
};

const isSameOrigin = (href: string) => new URL(href, window.location.href).origin === window.location.origin;

const visit = (href: string, newTab: boolean) => {
  if (newTab) window.open(href, "_blank", "noopener");
  else if (isSameOrigin(href)) router.visit(href);
  else window.location.assign(href);
};

type PanelProps = {
  onClose: () => void;
  pages: OmnibarShortcut[];
  actions: OmnibarShortcut[];
  pageSearch?: PageSearch | null;
  dictate?: boolean;
  agents?: OmnibarAgent[];
};

// Mounted with the dialog, so every opening starts from an empty field.
const OmnibarPanel = ({ onClose, pages, actions, pageSearch, dictate, agents = [] }: PanelProps) => {
  const [firstAgent] = agents;
  const fieldLabel = firstAgent
    ? `Search products, sales and pages, or ask ${firstAgent.name}`
    : "Search products, sales and pages";
  const [query, setQuery] = React.useState("");
  const inputRef = React.useRef<HTMLInputElement>(null);
  const dictation = useDictation((text) => setQuery(normalizeSearchQuery(text)));
  const canDictate = React.useMemo(isDictationSupported, []);
  React.useEffect(() => {
    if (dictate) dictation.start();
  }, []);
  const [search, setSearch] = React.useState<OmnibarResults & { query: string }>({ query: "" });
  const [activeId, setActiveId] = React.useState<string | null>(null);
  // Enter pressed before any row exists opens the first one that arrives.
  const pendingEnter = React.useRef(false);
  const uid = React.useId();
  const listId = `${uid}-list`;
  const optionId = (id: string) => `${uid}-${id}`;

  const trimmed = query.trim();
  const searchable = isSearchable(query);
  // Results for an earlier query say nothing about this one.
  const results: OmnibarResults = search.query === trimmed ? search : {};
  const searching = searchable && (results.products === undefined || results.sales === undefined);

  React.useEffect(() => {
    if (!searchable) return;
    const controller = new AbortController();
    const settle = (group: OmnibarResults) => {
      if (controller.signal.aborted) return;
      setSearch((previous) => ({ ...(previous.query === trimmed ? previous : { query: trimmed }), ...group }));
    };
    const timeout = window.setTimeout(() => {
      // Two requests, so a slow sales index never holds back the products.
      void searchOmnibarProducts(trimmed, controller.signal).then(
        (products) => settle({ products }),
        () => settle({ products: null }),
      );
      void searchOmnibarSales(trimmed, controller.signal).then(
        (sales) => settle({ sales }),
        () => settle({ sales: null }),
      );
    }, SEARCH_DELAY_MS);
    return () => {
      window.clearTimeout(timeout);
      controller.abort();
    };
  }, [searchable, trimmed]);

  const groups = React.useMemo(
    () =>
      buildOmnibarGroups({
        query,
        pages,
        actions,
        results,
        searchLinks: {
          sales: (value) => Routes.customers_path({ query: value }),
          products: (value) => Routes.products_path({ query: value }),
        },
        pageSearch: pageSearch
          ? { label: pageSearch.label, onSearch: pageSearch.onSearch, active: pageSearch.value !== "" }
          : null,
        agents,
      }),
    [query, pages, actions, results.products, results.sales, pageSearch, agents],
  );
  const items = groups.flatMap((group) => group.items);
  const activeItemId = nextActiveId(items, activeId);

  const select = (item: OmnibarItem, newTab = false) => {
    // A row that filters the page being viewed has nowhere to go, in this tab or a new one.
    if (!newTab || item.stay) {
      item.onSelect?.();
      onClose();
    }
    if (!item.stay) visit(item.href, newTab || item.external === true);
  };

  React.useEffect(() => {
    if (activeItemId) document.getElementById(optionId(activeItemId))?.scrollIntoView({ block: "nearest" });
  }, [activeItemId]);

  React.useEffect(() => {
    if (!pendingEnter.current) return;
    const [first] = items;
    if (first) select(first);
    if (first || !searching) pendingEnter.current = false;
  });

  const found = (results.products?.length ?? 0) + (results.sales?.length ?? 0);
  const note = !searchable
    ? items.length === 0
      ? "Keep typing to search your products and sales."
      : null
    : searching
      ? null
      : results.products === null && results.sales === null
        ? "Couldn't search your products and sales. You can still jump to a page."
        : results.sales === null
          ? "Sales can't be searched right now. Products and pages still can."
          : results.products === null
            ? "Products can't be searched right now. Sales and pages still can."
            : found === 0
              ? `No products or sales match “${trimmed}”.`
              : null;

  return (
    <>
      <div className="flex items-center gap-2 border-b border-border p-2">
        <InputGroup className="-outline-offset-2">
          {searching ? (
            <LoadingSpinner className="size-5" aria-label="Searching" />
          ) : (
            <SearchIcon className="size-5 shrink-0 text-muted" aria-hidden />
          )}
          <Input
            ref={inputRef}
            type="text"
            role="combobox"
            aria-label={fieldLabel}
            aria-expanded={items.length > 0}
            aria-controls={listId}
            aria-autocomplete="list"
            aria-activedescendant={activeItemId ? optionId(activeItemId) : undefined}
            autoComplete="off"
            placeholder={dictation.listening ? "Listening…" : fieldLabel}
            value={query}
            onChange={(event) => {
              pendingEnter.current = false;
              setQuery(normalizeSearchQuery(event.target.value));
            }}
            onKeyDown={(event) => {
              // Enter and the arrows belong to an input method while it is composing.
              if (event.nativeEvent.isComposing || event.nativeEvent.keyCode === IME_KEY_CODE) return;
              if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                event.preventDefault();
                setActiveId(moveActiveId(items, activeItemId, event.key === "ArrowDown" ? 1 : -1));
              } else if (event.key === "Enter") {
                event.preventDefault();
                const item = items.find(({ id }) => id === activeItemId);
                if (item) select(item, event.metaKey || event.ctrlKey);
                else pendingEnter.current = searching;
              }
            }}
          />
        </InputGroup>
        {canDictate ? (
          <button
            type="button"
            aria-label="Dictate"
            aria-pressed={dictation.listening}
            className={classNames(
              "cursor-pointer rounded p-2 all-unset",
              focusRing,
              // Filled while listening, so the state does not rest on colour alone.
              dictation.listening && "bg-foreground text-background",
            )}
            onClick={() => {
              if (dictation.listening) dictation.stop();
              else dictation.start();
              inputRef.current?.focus();
            }}
          >
            <Microphone className="size-5" aria-hidden />
          </button>
        ) : null}
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
                <div id={headingId} role="presentation" className="px-3 pt-3 pb-1 text-sm font-bold">
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
                        if (!item.stay && (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0))
                          return;
                        event.preventDefault();
                        select(item);
                      }}
                      onMouseMove={() => setActiveId(item.id)}
                      className={classNames(
                        "flex items-center gap-3 rounded px-3 py-2 no-underline",
                        // The outline marks the row without relying on the tint's 1.2:1 against the surface.
                        active && "bg-active-bg outline-1 -outline-offset-1 outline-foreground",
                      )}
                    >
                      <KindIcon kind={item.kind} />
                      {/* Stacked on a phone, so the buyer and the product each get the row's width. */}
                      <span className="flex min-w-0 flex-1 flex-col sm:flex-row sm:items-center sm:gap-3">
                        <span className="min-w-0 truncate sm:flex-1">{item.title}</span>
                        {item.detail ? (
                          <span className="min-w-0 truncate text-sm sm:max-w-1/2">{item.detail}</span>
                        ) : null}
                      </span>
                    </a>
                  );
                })}
              </div>
            );
          })}
        </div>
        {/* One live region: a note is shown, a bare result count is only announced. */}
        <p role="status" className={note ? "px-3 py-3 text-sm" : "sr-only"}>
          {searching ? "Searching" : (note ?? `${items.length} ${items.length === 1 ? "result" : "results"}`)}
        </p>
        {dictation.error ? (
          <p role="alert" className="px-3 py-3 text-sm">
            {dictation.error === "blocked"
              ? "The microphone is blocked for this site. Allow it in your browser to search by voice."
              : "Couldn't hear that. Try the microphone again, or type."}
          </p>
        ) : null}
      </div>
      <div aria-hidden className="hidden gap-4 border-t border-border px-4 py-2 text-sm sm:flex">
        <span>↑↓ to move</span>
        <span>↵ to open</span>
        <span>esc to close</span>
      </div>
    </>
  );
};

export const OmnibarDialog = ({ open, onClose, ...panel }: PanelProps & { open: boolean }) => {
  // The bar opens from a plain button or a shortcut, so the dialog has no trigger to return to.
  const returnFocus = React.useRef<HTMLElement | null>(null);

  return (
    <Dialog.Root open={open} onOpenChange={(next) => (next ? undefined : onClose())}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-backdrop" />
        <Dialog.Content
          aria-describedby={undefined}
          className="fixed inset-x-0 top-0 z-51 mx-auto flex max-h-dvh w-full flex-col border-b border-border bg-background text-foreground sm:top-[10vh] sm:max-h-[70vh] sm:max-w-xl sm:rounded sm:border sm:shadow-lg"
          onOpenAutoFocus={() => {
            returnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
          }}
          onCloseAutoFocus={(event) => {
            event.preventDefault();
            returnFocus.current?.focus();
          }}
        >
          <Dialog.Title className="sr-only">Search</Dialog.Title>
          <OmnibarPanel onClose={onClose} {...panel} />
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
};
