import React, { useState, useEffect } from "react";

export const AudiencePage: React.FC = () => {
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Simulate loading state
    const timer = setTimeout(() => setLoading(false), 500);
    return () => clearTimeout(timer);
  }, []);

  if (loading) {
    return (
      <div className="audience-page">
        <div className="flex h-32 items-center justify-center">
          <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-blue-600"></div>
          <span className="text-gray-600 ml-2">Loading audience data...</span>
        </div>
      </div>
    );
  }
  return (
    <div className="audience-page">
      <div className="border-gray-200 rounded-lg border bg-white p-6">
        <h2 className="text-gray-900 mb-4 text-lg font-semibold">Audience Overview</h2>
        <div className="py-12 text-center">
          <div className="mb-4 text-4xl">👥</div>
          <h3 className="text-gray-900 mb-2 text-lg font-medium">Audience Analytics</h3>
          <p className="text-gray-600 mb-4">Track your customer demographics and behavior</p>
          <div className="text-sm text-blue-600">🚧 Converting from server-side to SPA... Coming soon!</div>
        </div>
      </div>
    </div>
  );
};
