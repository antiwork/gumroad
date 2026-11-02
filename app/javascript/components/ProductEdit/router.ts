import { createBrowserRouter, matchPath, RouteObject } from "react-router-dom";

import { cast } from "$app/utils/cast";

const editedProductId = (pathname: string) => matchPath("/products/:id/edit/*", pathname)?.params.id;

// The editor is one Inertia page with a React Router inside it, and both listen to `popstate`.
// Inertia restores its page with `preserveState: false` (or reloads it for an entry that React
// Router pushed), so Back between two tabs mounts the editor again and drops every unsaved edit
// and in-flight upload. This router does not listen to `popstate` itself: `claimTabMove` (see
// utils/popstateClaims) takes a move between two tabs of the same product away from Inertia and
// gives it to React Router alone. Any other move still goes to Inertia.
export const createProductEditRouter = (routes: RouteObject[]) => {
  const popstateListeners = new Set<EventListener>();
  let initialIndex: number | null = null;

  // Inertia saves scroll positions by replacing the state of its own history entry, and that drops
  // the index React Router keeps there. Without the index, React Router cannot block a Back to that
  // entry, so put back the index the entry had when the router started.
  const history = {
    get state(): unknown {
      const state: unknown = window.history.state;
      if (initialIndex !== null && state && typeof state === "object" && !("idx" in state) && "page" in state)
        return { ...state, idx: initialIndex };
      return state;
    },
    pushState: (data: unknown, unused: string, url?: string | URL | null) =>
      window.history.pushState(data, unused, url),
    replaceState: (data: unknown, unused: string, url?: string | URL | null) =>
      window.history.replaceState(data, unused, url),
    go: (delta?: number) => window.history.go(delta),
  };

  const router = createBrowserRouter(routes, {
    window: cast<Window>({
      document: window.document,
      location: window.location,
      history,
      addEventListener: (type: string, listener: EventListener) => {
        if (type === "popstate") popstateListeners.add(listener);
        else window.addEventListener(type, listener);
      },
      removeEventListener: (type: string, listener: EventListener) => {
        if (type === "popstate") popstateListeners.delete(listener);
        else window.removeEventListener(type, listener);
      },
    }),
  });
  const startState: unknown = window.history.state;
  if (startState && typeof startState === "object" && "idx" in startState && typeof startState.idx === "number")
    initialIndex = startState.idx;

  const claimTabMove = (event: PopStateEvent) => {
    const productId = editedProductId(router.state.location.pathname);
    if (!productId || editedProductId(window.location.pathname) !== productId) return false;
    popstateListeners.forEach((listener) => listener(event));
    return true;
  };

  return { router, claimTabMove };
};
