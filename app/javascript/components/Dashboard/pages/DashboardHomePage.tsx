import React, { useState, useEffect } from "react";
import { DashboardPage } from "../../server-components/DashboardPage";

interface DashboardHomePageProps {}

interface DashboardData {
  name: string;
  has_sale: boolean;
  getting_started_stats: {
    customized_profile: boolean;
    first_follower: boolean;
    first_product: boolean;
    first_sale: boolean;
    first_payout: boolean;
    first_email: boolean;
    purchased_small_bets: boolean;
  };
  sales: Array<{
    id: string;
    name: string;
    thumbnail: string | null;
    sales: number;
    revenue: number;
    visits: number;
    today: number;
    last_7: number;
    last_30: number;
  }>;
  balances: {
    balance: string;
    last_seven_days_sales_total: string;
    last_28_days_sales_total: string;
    total: string;
  };
  activity_items: Array<any>;
  stripe_verification_message?: string | null;
  tax_forms: Record<number, string>;
  show_1099_download_notice: boolean;
}

export const DashboardHomePage: React.FC<DashboardHomePageProps> = () => {
  const [data, setData] = useState<DashboardData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const fetchDashboardData = async () => {
      try {
        setLoading(true);

        // Get CSRF token
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');

        const response = await fetch('/dashboard.json', {
          method: 'GET',
          headers: {
            'Content-Type': 'application/json',
            'X-CSRF-Token': csrfToken || '',
          },
        });

        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }

        const dashboardData = await response.json();
        setData(dashboardData);
      } catch (err) {
        console.error('Failed to fetch dashboard data:', err);
        setError(err instanceof Error ? err.message : 'Failed to load dashboard data');

        // Fallback data for development
        setData({
          name: "Developer",
          has_sale: false,
          getting_started_stats: {
            customized_profile: false,
            first_follower: false,
            first_product: false,
            first_sale: false,
            first_payout: false,
            first_email: false,
            purchased_small_bets: false,
          },
          sales: [],
          balances: {
            balance: "$0.00",
            last_seven_days_sales_total: "$0.00",
            last_28_days_sales_total: "$0.00",
            total: "$0.00",
          },
          activity_items: [],
          tax_forms: {},
          show_1099_download_notice: false,
        });
      } finally {
        setLoading(false);
      }
    };

    fetchDashboardData();
  }, []);

  if (loading) {
    return (
      <div style={{
        display: "flex",
        justifyContent: "center",
        alignItems: "center",
        height: "400px"
      }}>
        <div style={{ textAlign: "center" }}>
          <div style={{
            width: "40px",
            height: "40px",
            border: "4px solid #f3f4f6",
            borderTop: "4px solid #3b82f6",
            borderRadius: "50%",
            animation: "spin 1s linear infinite",
            margin: "0 auto 1rem"
          }} />
          <p>Loading dashboard...</p>
        </div>
      </div>
    );
  }

  if (error && !data) {
    return (
      <div style={{
        padding: "2rem",
        textAlign: "center",
        backgroundColor: "#fef2f2",
        border: "1px solid #fecaca",
        borderRadius: "0.5rem",
        color: "#dc2626"
      }}>
        <h3>Error loading dashboard</h3>
        <p>{error}</p>
        <button
          onClick={() => window.location.reload()}
          style={{
            padding: "0.5rem 1rem",
            backgroundColor: "#dc2626",
            color: "white",
            border: "none",
            borderRadius: "0.25rem",
            cursor: "pointer"
          }}
        >
          Retry
        </button>
      </div>
    );
  }

  if (!data) {
    return null;
  }

  return (
    <div className="dashboard-home-page">
      {error && (
        <div style={{
          marginBottom: "1rem",
          padding: "0.75rem",
          backgroundColor: "#fef3cd",
          border: "1px solid #fbbf24",
          borderRadius: "0.25rem",
          color: "#92400e"
        }}>
          Warning: {error} (showing fallback data)
        </div>
      )}

      <DashboardPage {...data} />

      <style dangerouslySetInnerHTML={{
        __html: `
          @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
          }
        `
      }} />
    </div>
  );
};

export default DashboardHomePage;
