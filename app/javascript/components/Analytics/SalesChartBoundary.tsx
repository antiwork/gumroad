import * as React from "react";

import { Button } from "$app/components/Button";

// A failed chunk fetch is a render error, so without a boundary React unmounts everything above it
// — the seller loses the whole Analytics page because one chart could not download. Everything else
// on this page (stats, referrers, locations) is independent of the chart and still worth reading,
// so the failure is contained to the chart's own box.
//
// Reloading is the recovery rather than a local retry: `React.lazy` permanently caches the rejected
// import, so there is no way to ask it again within this document. A reload also picks up a fresh
// asset manifest, which fixes the other real cause here — a deploy re-hashing the chunk filename
// while the seller had the page open.
const SalesChartLoadFailed = () => (
  <div role="alert" className="flex flex-col items-center gap-3 p-8 text-center">
    <p>We couldn&apos;t load the sales chart. Your sales data is unaffected.</p>
    <Button onClick={() => location.reload()}>Reload</Button>
  </div>
);

// Error boundaries have no hook equivalent, so this has to be a class component.
export class SalesChartBoundary extends React.Component<{ children: React.ReactNode }, { failed: boolean }> {
  constructor(props: { children: React.ReactNode }) {
    super(props);
    this.state = { failed: false };
  }

  static getDerivedStateFromError() {
    return { failed: true };
  }

  override render() {
    return this.state.failed ? <SalesChartLoadFailed /> : this.props.children;
  }
}
