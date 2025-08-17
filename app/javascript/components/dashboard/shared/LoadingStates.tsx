import React from "react";
import cx from "classnames";

interface LoadingSpinnerProps {
  size?: "small" | "medium" | "large";
  className?: string;
}

export const LoadingSpinner: React.FC<LoadingSpinnerProps> = ({ 
  size = "medium", 
  className 
}) => {
  return (
    <div className={cx("dashboard-spa-loading-spinner", `size-${size}`, className)}>
      <div className="spinner" />
    </div>
  );
};

interface LoadingSkeletonProps {
  lines?: number;
  className?: string;
}

export const LoadingSkeleton: React.FC<LoadingSkeletonProps> = ({ 
  lines = 3, 
  className 
}) => {
  return (
    <div className={cx("dashboard-spa-loading-skeleton", className)}>
      {Array.from({ length: lines }).map((_, index) => (
        <div 
          key={index} 
          className="skeleton-line"
          style={{ width: `${Math.random() * 40 + 60}%` }}
        />
      ))}
    </div>
  );
};

interface PageLoadingProps {
  message?: string;
}

export const PageLoading: React.FC<PageLoadingProps> = ({ message = "Loading..." }) => {
  return (
    <div className="dashboard-spa-page-loading">
      <LoadingSpinner size="large" />
      <p className="loading-message">{message}</p>
    </div>
  );
};

interface LoadingProgressProps {
  progress: number;
  label?: string;
}

export const LoadingProgress: React.FC<LoadingProgressProps> = ({ progress, label }) => {
  return (
    <div className="dashboard-spa-loading-progress">
      {label && <div className="progress-label">{label}</div>}
      <div className="progress-bar">
        <div 
          className="progress-fill" 
          style={{ width: `${Math.min(100, Math.max(0, progress))}%` }}
        />
      </div>
      <div className="progress-value">{Math.round(progress)}%</div>
    </div>
  );
};

interface TableLoadingProps {
  rows?: number;
  columns?: number;
}

export const TableLoading: React.FC<TableLoadingProps> = ({ 
  rows = 5, 
  columns = 4 
}) => {
  return (
    <table className="dashboard-spa-table-loading">
      <thead>
        <tr>
          {Array.from({ length: columns }).map((_, index) => (
            <th key={index}>
              <div className="skeleton-cell" />
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {Array.from({ length: rows }).map((_, rowIndex) => (
          <tr key={rowIndex}>
            {Array.from({ length: columns }).map((_, colIndex) => (
              <td key={colIndex}>
                <div className="skeleton-cell" />
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
};

interface StatsLoadingProps {
  count?: number;
}

export const StatsLoading: React.FC<StatsLoadingProps> = ({ count = 4 }) => {
  return (
    <div className="stats-grid">
      {Array.from({ length: count }).map((_, index) => (
        <div key={index} className="dashboard-spa-stats-loading">
          <div className="skeleton-title" />
          <div className="skeleton-value" />
          <div className="skeleton-description" />
        </div>
      ))}
    </div>
  );
};