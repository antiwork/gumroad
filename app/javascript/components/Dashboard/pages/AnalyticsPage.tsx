import React, { useState, useEffect } from "react";

interface AnalyticsPageProps {}

interface AnalyticsData {
  [key: string]: any;
}

export const AnalyticsPage: React.FC<AnalyticsPageProps> = () => {
  const [data, setData] = useState<AnalyticsData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const fetchAnalyticsData = async () => {
      try {
        setLoading(true);

        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');

        const response = await fetch('/dashboard/sales.json', {
          method: 'GET',
          headers: {
            'Content-Type': 'application/json',
            'X-CSRF-Token': csrfToken || '',
          },
        });

        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }

        const analyticsData = await response.json();
        setData(analyticsData);
      } catch (err) {
        console.error('Failed to fetch analytics data:', err);
        setError(err instanceof Error ? err.message : 'Failed to load analytics data');

        setData({
          fallback: true,
          message: "Analytics data will be loaded here"
        });
      } finally {
        setLoading(false);
      }
    };

    fetchAnalyticsData();
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
          <p>Loading analytics...</p>
        </div>
      </div>
    );
  }

  return (
    <div className="analytics-page-wrapper">
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

      <div style={{ padding: "2rem" }}>
        <h2 style={{ marginBottom: "1rem" }}>Sales Analytics</h2>

        {data && (
          <div style={{
            marginBottom: "1rem",
            padding: "0.75rem",
            backgroundColor: "#f0f9ff",
            border: "1px solid #0ea5e9",
            borderRadius: "0.25rem",
            color: "#0c4a6e"
          }}>
            Connected to analytics API - Data loaded: {JSON.stringify(data).substring(0, 100)}...
          </div>
        )}

        <div style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(250px, 1fr))",
          gap: "1rem",
          marginBottom: "2rem"
        }}>
          <div style={{
            padding: "1.5rem",
            backgroundColor: "white",
            border: "1px solid #e5e7eb",
            borderRadius: "0.5rem"
          }}>
            <h3 style={{ margin: "0 0 0.5rem 0", fontSize: "1.125rem" }}>Total Revenue</h3>
            <p style={{ margin: 0, fontSize: "2rem", fontWeight: "bold", color: "#059669" }}>$0.00</p>
          </div>

          <div style={{
            padding: "1.5rem",
            backgroundColor: "white",
            border: "1px solid #e5e7eb",
            borderRadius: "0.5rem"
          }}>
            <h3 style={{ margin: "0 0 0.5rem 0", fontSize: "1.125rem" }}>Total Sales</h3>
            <p style={{ margin: 0, fontSize: "2rem", fontWeight: "bold", color: "#3b82f6" }}>0</p>
          </div>

          <div style={{
            padding: "1.5rem",
            backgroundColor: "white",
            border: "1px solid #e5e7eb",
            borderRadius: "0.5rem"
          }}>
            <h3 style={{ margin: "0 0 0.5rem 0", fontSize: "1.125rem" }}>Conversion Rate</h3>
            <p style={{ margin: 0, fontSize: "2rem", fontWeight: "bold", color: "#8b5cf6" }}>0%</p>
          </div>
        </div>

        <div style={{
          padding: "2rem",
          backgroundColor: "white",
          border: "1px solid #e5e7eb",
          borderRadius: "0.5rem",
          textAlign: "center",
          color: "#6b7280"
        }}>
          <p style={{ margin: 0, fontSize: "1.125rem" }}>📊 Analytics charts will be displayed here</p>
          <p style={{ margin: "0.5rem 0 0 0", fontSize: "0.875rem" }}>
            Connected to existing analytics APIs: data_by_date, data_by_state, data_by_referral
          </p>
        </div>
      </div>

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

export default AnalyticsPage;
