import * as React from "react";

import { Button } from "$app/components/Button";

// Keep chart chunk failures inside the chart box; the rest of Analytics remains useful.
// Reloading is the recovery because React.lazy caches a rejected import for this document.
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
