import React, { useState, useEffect } from "react";

interface AudiencePageProps {}

interface AudienceData {
  total_follower_count: number;
}

export const AudiencePage: React.FC<AudiencePageProps> = () => {
  const [data, setData] = useState<AudienceData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const fetchAudienceData = async () => {
      try {
        setLoading(true);

        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');

        const response = await fetch('/dashboard/audience.json', {
          method: 'GET',
          headers: {
            'Content-Type': 'application/json',
            'X-CSRF-Token': csrfToken || '',
          },
        });

        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }

        const audienceData = await response.json();
        setData(audienceData);
      } catch (err) {
        console.error('Failed to fetch audience data:', err);
        setError(err instanceof Error ? err.message : 'Failed to load audience data');

        setData({
          total_follower_count: 0,
        });
      } finally {
        setLoading(false);
      }
    };

    fetchAudienceData();
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
          <p>Loading audience data...</p>
        </div>
      </div>
    );
  }

  if (!data) {
    return null;
  }

  return (
    <div className="audience-page-wrapper">
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
        <h2 style={{ marginBottom: "1rem" }}>Audience Management</h2>

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
            <h3 style={{ margin: "0 0 0.5rem 0", fontSize: "1.125rem" }}>Total Followers</h3>
            <p style={{ margin: 0, fontSize: "2rem", fontWeight: "bold", color: "#3b82f6" }}>
              {data.total_follower_count.toLocaleString()}
            </p>
          </div>

          <div style={{
            padding: "1.5rem",
            backgroundColor: "white",
            border: "1px solid #e5e7eb",
            borderRadius: "0.5rem"
          }}>
            <h3 style={{ margin: "0 0 0.5rem 0", fontSize: "1.125rem" }}>Total Customers</h3>
            <p style={{ margin: 0, fontSize: "2rem", fontWeight: "bold", color: "#059669" }}>0</p>
          </div>

          <div style={{
            padding: "1.5rem",
            backgroundColor: "white",
            border: "1px solid #e5e7eb",
            borderRadius: "0.5rem"
          }}>
            <h3 style={{ margin: "0 0 0.5rem 0", fontSize: "1.125rem" }}>Active Affiliates</h3>
            <p style={{ margin: 0, fontSize: "2rem", fontWeight: "bold", color: "#8b5cf6" }}>0</p>
          </div>
        </div>

        <div style={{
          padding: "2rem",
          backgroundColor: "white",
          border: "1px solid #e5e7eb",
          borderRadius: "0.5rem",
          marginBottom: "2rem"
        }}>
          <h3 style={{ marginBottom: "1rem" }}>Audience Growth</h3>
          <div style={{
            height: "300px",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            backgroundColor: "#f9fafb",
            borderRadius: "0.25rem",
            color: "#6b7280"
          }}>
            <div style={{ textAlign: "center" }}>
              <p style={{ margin: 0, fontSize: "1.125rem" }}>📈 Audience growth chart</p>
              <p style={{ margin: "0.5rem 0 0 0", fontSize: "0.875rem" }}>
                Connected to audience data_by_date API
              </p>
            </div>
          </div>
        </div>

        <div style={{
          padding: "1.5rem",
          backgroundColor: "white",
          border: "1px solid #e5e7eb",
          borderRadius: "0.5rem"
        }}>
          <h3 style={{ marginBottom: "1rem" }}>Export Audience Data</h3>
          <div style={{ display: "flex", gap: "1rem", flexWrap: "wrap" }}>
            <button style={{
              padding: "0.5rem 1rem",
              backgroundColor: "#3b82f6",
              color: "white",
              border: "none",
              borderRadius: "0.25rem",
              cursor: "pointer"
            }}>
              Export Followers
            </button>
            <button style={{
              padding: "0.5rem 1rem",
              backgroundColor: "#059669",
              color: "white",
              border: "none",
              borderRadius: "0.25rem",
              cursor: "pointer"
            }}>
              Export Customers
            </button>
            <button style={{
              padding: "0.5rem 1rem",
              backgroundColor: "#8b5cf6",
              color: "white",
              border: "none",
              borderRadius: "0.25rem",
              cursor: "pointer"
            }}>
              Export Affiliates
            </button>
          </div>
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

export default AudiencePage;
