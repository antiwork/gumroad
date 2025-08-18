import React, { useEffect } from "react";

const BalanceRoute: React.FC = () => {
  useEffect(() => {
    window.location.replace("/payouts");
  }, []);

  return (
    <div className="dashboard-spa-balance">
      <h1>Balance</h1>
      <p>Redirecting to payouts page...</p>
    </div>
  );
};

export default BalanceRoute;