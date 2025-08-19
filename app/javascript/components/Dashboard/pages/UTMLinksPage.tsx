import React, { useState, useEffect } from "react";

interface UTMLinksPageProps {}

export const UTMLinksPage: React.FC<UTMLinksPageProps> = () => {
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const timer = setTimeout(() => {
      setLoading(false);
    }, 500);

    return () => clearTimeout(timer);
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
          <p>Loading UTM links...</p>
        </div>
      </div>
    );
  }

  return (
    <div className="utm-links-page-wrapper">
      <div style={{ padding: "2rem" }}>
        <h2 style={{ marginBottom: "1rem" }}>UTM Link Management</h2>

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
            <h3 style={{ margin: "0 0 0.5rem 0", fontSize: "1.125rem" }}>Total UTM Links</h3>
            <p style={{ margin: 0, fontSize: "2rem", fontWeight: "bold", color: "#3b82f6" }}>0</p>
          </div>

          <div style={{
            padding: "1.5rem",
            backgroundColor: "white",
            border: "1px solid #e5e7eb",
            borderRadius: "0.5rem"
          }}>
            <h3 style={{ margin: "0 0 0.5rem 0", fontSize: "1.125rem" }}>Total Clicks</h3>
            <p style={{ margin: 0, fontSize: "2rem", fontWeight: "bold", color: "#059669" }}>0</p>
          </div>

          <div style={{
            padding: "1.5rem",
            backgroundColor: "white",
            border: "1px solid #e5e7eb",
            borderRadius: "0.5rem"
          }}>
            <h3 style={{ margin: "0 0 0.5rem 0", fontSize: "1.125rem" }}>Conversions</h3>
            <p style={{ margin: 0, fontSize: "2rem", fontWeight: "bold", color: "#8b5cf6" }}>0</p>
          </div>
        </div>

        <div style={{
          padding: "1.5rem",
          backgroundColor: "white",
          border: "1px solid #e5e7eb",
          borderRadius: "0.5rem",
          marginBottom: "2rem"
        }}>
          <h3 style={{ marginBottom: "1rem" }}>Create New UTM Link</h3>
          <div style={{ display: "grid", gap: "1rem", maxWidth: "600px" }}>
            <div>
              <label style={{ display: "block", marginBottom: "0.5rem", fontWeight: "500" }}>
                Product URL
              </label>
              <input
                type="url"
                placeholder="https://gumroad.com/l/your-product"
                style={{
                  width: "100%",
                  padding: "0.5rem",
                  border: "1px solid #d1d5db",
                  borderRadius: "0.25rem",
                  fontSize: "0.875rem"
                }}
              />
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "1rem" }}>
              <div>
                <label style={{ display: "block", marginBottom: "0.5rem", fontWeight: "500" }}>
                  Campaign Source
                </label>
                <input
                  type="text"
                  placeholder="twitter"
                  style={{
                    width: "100%",
                    padding: "0.5rem",
                    border: "1px solid #d1d5db",
                    borderRadius: "0.25rem",
                    fontSize: "0.875rem"
                  }}
                />
              </div>

              <div>
                <label style={{ display: "block", marginBottom: "0.5rem", fontWeight: "500" }}>
                  Campaign Medium
                </label>
                <input
                  type="text"
                  placeholder="social"
                  style={{
                    width: "100%",
                    padding: "0.5rem",
                    border: "1px solid #d1d5db",
                    borderRadius: "0.25rem",
                    fontSize: "0.875rem"
                  }}
                />
              </div>
            </div>

            <div>
              <label style={{ display: "block", marginBottom: "0.5rem", fontWeight: "500" }}>
                Campaign Name
              </label>
              <input
                type="text"
                placeholder="summer_sale_2025"
                style={{
                  width: "100%",
                  padding: "0.5rem",
                  border: "1px solid #d1d5db",
                  borderRadius: "0.25rem",
                  fontSize: "0.875rem"
                }}
              />
            </div>

            <button style={{
              padding: "0.75rem 1.5rem",
              backgroundColor: "#3b82f6",
              color: "white",
              border: "none",
              borderRadius: "0.25rem",
              cursor: "pointer",
              fontSize: "0.875rem",
              fontWeight: "500",
              justifySelf: "start"
            }}>
              Generate UTM Link
            </button>
          </div>
        </div>

        <div style={{
          backgroundColor: "white",
          border: "1px solid #e5e7eb",
          borderRadius: "0.5rem",
          overflow: "hidden"
        }}>
          <div style={{
            padding: "1.5rem 1.5rem 1rem 1.5rem",
            borderBottom: "1px solid #e5e7eb"
          }}>
            <h3 style={{ margin: 0 }}>Your UTM Links</h3>
          </div>

          <div style={{
            padding: "2rem",
            textAlign: "center",
            color: "#6b7280"
          }}>
            <p style={{ margin: 0, fontSize: "1.125rem" }}>🔗 No UTM links created yet</p>
            <p style={{ margin: "0.5rem 0 0 0", fontSize: "0.875rem" }}>
              Create your first UTM link to start tracking your marketing campaigns
            </p>
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

export default UTMLinksPage;
