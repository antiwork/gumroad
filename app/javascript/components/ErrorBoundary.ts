import * as React from "react";

type Props = { placeholder: React.ReactNode; children: React.ReactNode };

type State = { hasError: boolean };

class ErrorBoundary extends React.Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError() {
    // Update state so the next render will show the fallback UI.
    return { hasError: true };
  }

  override render() {
    if (this.state.hasError) {
      return this.props.placeholder;
    }

    return this.props.children;
  }
}

export { ErrorBoundary };
