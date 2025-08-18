import { useDashboardStore, useDashboardState } from "$app/services/state/dashboardStore";
import { useCallback } from "react";

interface APIOptions {
  useCache?: boolean;
  cacheKey?: string;
  maxAge?: number;
}

interface DashboardStats {
  customers_count: string;
  total_revenue: string;
  active_members_count: string;
  monthly_recurring_revenue: string;
}

class DashboardAPIService {
  private baseURL = "/api/internal";

  private async fetchWithAuth(url: string, options: RequestInit = {}) {
    const response = await fetch(url, {
      ...options,
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest",
        "X-CSRF-Token": this.getCSRFToken(),
        ...options.headers,
      },
      credentials: "same-origin",
    });

    if (!response.ok) {
      throw new Error(`API Error: ${response.status} ${response.statusText}`);
    }

    return response.json();
  }

  private getCSRFToken(): string {
    const token = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content");
    return token || "";
  }

  async getDashboardData() {
    return this.fetchWithAuth(`${this.baseURL}/dashboard`);
  }

  async getDashboardStats(): Promise<DashboardStats> {
    const resp = await this.fetchWithAuth(`${this.baseURL}/dashboard/stats`);
    return resp.data as DashboardStats;
  }

  async getAnalyticsData(startDate?: string, endDate?: string) {
    const params = new URLSearchParams();
    if (startDate) params.append("start_time", startDate);
    if (endDate) params.append("end_time", endDate);

    return this.fetchWithAuth(`/analytics/data_by_date?${params}`);
  }

  async getProductsData(page = 1) {
    return this.fetchWithAuth(`${this.baseURL}/products?page=${page}`);
  }

  async getAudienceData() {
    return this.fetchWithAuth(`${this.baseURL}/audience`);
  }
}

export const dashboardAPI = new DashboardAPIService();

// Custom hooks for using the API with caching
export const useDashboardAPI = () => {
  const { setCache, getCache, setLoading, setError, isStale } = useDashboardStore();
  const state = useDashboardState();

  const fetchWithCache = useCallback(
    async <T>(
      key: string,
      fetcher: () => Promise<T>,
      options: APIOptions = {}
    ): Promise<T> => {
      const { useCache = true, maxAge = 5 * 60 * 1000 } = options;

      // Check cache first
      if (useCache && !isStale(key, maxAge)) {
        const cached = getCache(key);
        if (cached) return cached;
      }

      setLoading(key, true);
      setError(key, null);

      try {
        const data = await fetcher();
        if (useCache) {
          setCache(key, data);
        }
        return data;
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : "Unknown error";
        setError(key, errorMessage);
        throw error;
      } finally {
        setLoading(key, false);
      }
    },
    [setCache, getCache, setLoading, setError, isStale]
  );

  return {
    fetchDashboardData: useCallback(
      (options?: APIOptions) =>
        fetchWithCache("dashboard", () => dashboardAPI.getDashboardData(), options),
      [fetchWithCache]
    ),

    fetchDashboardStats: useCallback(
      (options?: APIOptions) =>
        fetchWithCache("dashboard_stats", () => dashboardAPI.getDashboardStats(), options),
      [fetchWithCache]
    ),

    fetchAnalyticsData: useCallback(
      (startDate?: string, endDate?: string, options?: APIOptions) => {
        const hasRange = Boolean(startDate || endDate);
        const key = hasRange ? `analytics_${startDate}_${endDate}` : "analytics";
        return fetchWithCache(key, () => dashboardAPI.getAnalyticsData(startDate, endDate), options);
      },
      [fetchWithCache]
    ),

    fetchProductsData: useCallback(
      (page = 1, options?: APIOptions) =>
        fetchWithCache(`products_${page}`, () => dashboardAPI.getProductsData(page), options),
      [fetchWithCache]
    ),

    fetchAudienceData: useCallback(
      (options?: APIOptions) =>
        fetchWithCache("audience", () => dashboardAPI.getAudienceData(), options),
      [fetchWithCache]
    ),

    isLoading: (key: string) => state.loading[key] || false,
    getError: (key: string) => state.errors[key] || null,
    getCachedData: getCache,
  };
};