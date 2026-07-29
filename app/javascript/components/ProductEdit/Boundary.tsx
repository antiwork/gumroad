import * as React from "react";

import { Button, NavigationButton } from "$app/components/Button";
import { attemptRecoveryReload, ProductEditChunkLoadError } from "$app/components/ProductEdit/load";

// Catches the case where the product editor's code cannot be downloaded at all.
//
// The editor is loaded as a separate chunk (see ProductEdit/load), which means opening a product
// depends on a network request that can fail — an offline moment, a proxy that drops the connection,
// a CDN edge briefly serving an error. `load` already retries once for the momentary blips, so
// anything reaching this boundary is a genuine failure.
//
// Without a boundary, React treats that failed import as a render error and unmounts everything
// above it, which leaves the seller on a blank page — the same "clicking a product does nothing"
// complaint this PR exists to fix, just with a different cause (gumroad-private#1469). So the
// failure gets its own visible, recoverable state instead.
//
// Reloading is the recovery rather than a local retry: `React.lazy` permanently caches the rejected
// import, so once it has failed there is no way to ask it again within the same page. A reload also
// picks up a fresh asset manifest, which is what fixes the other real cause of this failure — a
// deploy replacing the chunk filenames while the seller had the old page open.
//
// The way back is a real link to the Products list rather than a "go back in history" action,
// because the seller may not have come from the list at all: the editor can be opened in a new tab,
// from a bookmark, or from a link in an email, and in those cases there is either no history to go
// back to or the previous entry belongs to some unrelated site. A link always lands somewhere
// useful, and it behaves like a link should — middle-click, open in a new tab, copy the address.
const ProductEditLoadFailed = () => (
  <div role="alert" className="flex flex-col items-center gap-4 p-8 text-center">
    <h2>We couldn&apos;t open this product</h2>
    <p>Something went wrong loading the editor. Your product and its settings are unaffected.</p>
    <div className="flex gap-3">
      <NavigationButton href={Routes.products_path()}>Back to products</NavigationButton>
      <Button color="primary" onClick={() => location.reload()}>
        Try again
      </Button>
    </div>
  </div>
);

// Error boundaries have no hook equivalent, so this has to be a class component.
export class ProductEditBoundary extends React.Component<{ children: React.ReactNode }, { failed: boolean }> {
  constructor(props: { children: React.ReactNode }) {
    super(props);
    this.state = { failed: false };
  }

  static getDerivedStateFromError() {
    return { failed: true };
  }

  // Before showing the seller an error, try the one recovery that actually fixes the most common
  // version of this failure. The browser remembers a dynamic import that failed and will not fetch
  // it again in this document, so a background prefetch that failed during a brief network problem
  // keeps failing afterwards even once the connection is fine. A reload starts a fresh document,
  // which is the only way to get a real request for that chunk again. `attemptRecoveryReload` does
  // it at most once per tab, so a real outage still ends up here showing the error rather than
  // reloading in circles.
  //
  // Only when the editor's code never arrived, though. Once it has downloaded, anything reaching
  // this boundary came from the editor running — a bad prop, a crash in a child — and a reload
  // cannot help with that: the fresh document downloads the chunk successfully, which clears the
  // "already reloaded once" marker, and then hits the same deterministic error and reloads again.
  // That is an endless loop, and the seller never reaches this error screen with its way out. So the
  // reload is offered only for the failure a reload can actually fix, which the loader marks with
  // its own error type.
  override componentDidCatch(error: unknown) {
    if (error instanceof ProductEditChunkLoadError) attemptRecoveryReload();
  }

  override render() {
    return this.state.failed ? <ProductEditLoadFailed /> : this.props.children;
  }
}
