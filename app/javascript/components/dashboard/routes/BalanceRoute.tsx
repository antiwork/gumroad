import React, { useEffect } from "react";

const BalanceRoute: React.FC = () => {
  useEffect(() => {
    // For now, redirect to existing balance page
    window.location.href = "/balance";
  }, []);

  return (
    <div className="dashboard-spa-balance">
      <h1>Balance</h1>
      <p>Redirecting to balance page...</p>
    </div>
  );
};

export default BalanceRoute;