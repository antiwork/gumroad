import type { ComponentType } from 'react';

export interface DashboardProps {
  user_name?: string;
  stats?: DashboardStats;
  [key: string]: any;
}

export interface DashboardStats {
  revenue?: number;
  sales?: number;
  products?: number;
  views?: number;
  conversion?: number;
}

export interface AnalyticsData {
  revenue: number;
  sales: number;
  views: number;
  conversion: number;
  chart_data?: ChartData;
}

export interface ChartData {
  labels: string[];
  datasets: ChartDataset[];
}

export interface ChartDataset {
  label: string;
  data: number[];
  backgroundColor?: string;
  borderColor?: string;
}

export interface ApiResponse<T = any> {
  data?: T;
  error?: string;
  message?: string;
}

export interface LoadingState {
  loading: boolean;
  error: string | null;
}

export interface RouteConfig {
  path: string;
  label: string;
  icon: string;
  component?: ComponentType;
}
export const API_ENDPOINTS = {
  ANALYTICS: '/internal/dashboard/analytics',
  STATS: '/internal/dashboard/stats',
  AUDIENCE: '/internal/dashboard/audience',
  UTM_LINKS: '/internal/dashboard/utm_links',
  PRODUCTS: '/internal/dashboard/products'
} as const;

export type ApiEndpoint = typeof API_ENDPOINTS[keyof typeof API_ENDPOINTS];
