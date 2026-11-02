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

export const installPopstateClaims = (target: Window = window): void => {
  target.addEventListener("popstate", (event) => {
    for (const claim of claims) {
      if (claim(event)) {
        event.stopImmediatePropagation();
        return;
      }
    }
  });
};
