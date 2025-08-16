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
        <div className="flex items-center justify-center h-32">
          <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-blue-600"></div>
          <span className="ml-2 text-gray-600">Loading UTM links...</span>
        </div>
      </div>
    );
  }
  return (
    <div className="utm-links-page">
      <div className="bg-white rounded-lg border border-gray-200 p-6">
        <h2 className="text-lg font-semibold text-gray-900 mb-4">UTM Links</h2>
        <div className="text-center py-12">
          <div className="text-4xl mb-4">🔗</div>
          <h3 className="text-lg font-medium text-gray-900 mb-2">Marketing Links</h3>
          <p className="text-gray-600 mb-4">Create and track your marketing campaign links</p>
          <div className="text-sm text-blue-600">
            🚧 Converting from server-side to SPA... Coming soon!
          </div>
        </div>
      </div>
    </div>
  );
};
