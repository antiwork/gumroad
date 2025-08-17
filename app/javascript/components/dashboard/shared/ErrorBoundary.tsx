import React, { Component, ErrorInfo, ReactNode } from "react";
import { Icon } from "$app/components/Icons";

interface Props {
  children: ReactNode;
  fallback?: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
  errorInfo: ErrorInfo | null;
}

export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = {
      hasError: false,
      error: null,
      errorInfo: null,
    };
  }

  static getDerivedStateFromError(error: Error): State {
    return {
      hasError: true,
      error,
      errorInfo: null,
    };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error("Dashboard SPA Error:", error, errorInfo);
    
    this.setState({
      error,
      errorInfo,
    });

    // Report to error tracking service
    if (window.Sentry) {
      window.Sentry.captureException(error, {
        contexts: {
          react: {
            componentStack: errorInfo.componentStack,
          },
        },
      });
    }
  }

  handleReset = () => {
    this.setState({
      hasError: false,
      error: null,
      errorInfo: null,
    });
  };

  render() {
    if (this.state.hasError) {
      if (this.props.fallback) {
        return <>{this.props.fallback}</>;
      }

      return (
        <div className="dashboard-spa-error-boundary">
          <div className="error-content">
            <Icon name="exclamation-triangle-fill" className="error-icon" />
            <h2>Something went wrong</h2>
            <p>We encountered an unexpected error. Please try refreshing the page.</p>
            
            {process.env.NODE_ENV === "development" && this.state.error && (
              <details className="error-details">
                <summary>Error details</summary>
                <pre className="error-stack">
                  {this.state.error.toString()}
                  {this.state.errorInfo?.componentStack}
                </pre>
              </details>
            )}
            
            <div className="error-actions">
              <button 
                className="button primary"
                onClick={() => window.location.reload()}
              >
                Refresh page
              </button>
              <button 
                className="button ghost"
                onClick={this.handleReset}
              >
                Try again
              </button>
            </div>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}

interface ErrorFallbackProps {
  error?: Error;
  resetError?: () => void;
}

export const ErrorFallback: React.FC<ErrorFallbackProps> = ({ error, resetError }) => {
  return (
    <div className="dashboard-spa-error-fallback">
      <Icon name="exclamation-circle-fill" className="error-icon" />
      <h3>Failed to load this section</h3>
      <p>{error?.message || "An unexpected error occurred"}</p>
      {resetError && (
        <button className="button primary" onClick={resetError}>
          Try again
        </button>
      )}
    </div>
  );
};