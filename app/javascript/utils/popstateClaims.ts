// Inertia handles every `popstate` and restores its page from the history entry, which mounts the
// page again. A page with its own client-side routes (the product editor) claims the Back and
// Forward moves between those routes, so Inertia leaves them alone. Listeners on `window` run in
// the order they were added, so this listener must be installed before Inertia starts.
type PopstateClaim = (event: PopStateEvent) => boolean;

const claims = new Set<PopstateClaim>();

export const claimPopstate = (claim: PopstateClaim): (() => void) => {
  claims.add(claim);
  return () => {
    claims.delete(claim);
  };
};

// True from a Back or Forward that Inertia answers out of the history entry until the next visit
// starts. The props such a page mounts with are the ones its entry was first loaded with, so a page
// that saves from its props (the product editor) reloads them before it lets the seller edit.
let restoredFromHistory = false;

export const pageWasRestoredFromHistory = (): boolean => restoredFromHistory;

export const markVisitStarted = (): void => {
  restoredFromHistory = false;
};

export const installPopstateClaims = (target: Window = window): void => {
  target.addEventListener("popstate", (event) => {
    for (const claim of claims) {
      if (claim(event)) {
        event.stopImmediatePropagation();
        return;
      }
    }
    restoredFromHistory = true;
  });
};
