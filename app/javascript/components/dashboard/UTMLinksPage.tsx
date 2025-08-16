import React, { useState, useEffect } from "react";

export const UTMLinksPage: React.FC = () => {
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const timer = setTimeout(() => setLoading(false), 300);
    return () => clearTimeout(timer);
  }, []);

  if (loading) {
    return (
      <div className="utm-links-page">
        <div className="flex h-32 items-center justify-center">
          <div className="h-6 w-6 animate-spin rounded-full border-b-2 border-blue-600"></div>
          <span className="text-gray-600 ml-2">Loading UTM links...</span>
        </div>
      </div>
    );
  }
  return (
    <div className="utm-links-page">
      <div className="border-gray-200 rounded-lg border bg-white p-6">
        <h2 className="text-gray-900 mb-4 text-lg font-semibold">UTM Links</h2>
        <div className="py-12 text-center">
          <div className="mb-4 text-4xl">🔗</div>
          <h3 className="text-gray-900 mb-2 text-lg font-medium">Marketing Links</h3>
          <p className="text-gray-600 mb-4">Create and track your marketing campaign links</p>
          <div className="text-sm text-blue-600">🚧 Converting from server-side to SPA... Coming soon!</div>
        </div>
      </div>
    </div>
  );
};
