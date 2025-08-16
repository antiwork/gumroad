import React, { useState, useEffect } from "react";

export const ProductsPage: React.FC = () => {
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const timer = setTimeout(() => setLoading(false), 400);
    return () => clearTimeout(timer);
  }, []);

  if (loading) {
    return (
      <div className="products-page">
        <div className="flex h-32 items-center justify-center">
          <div className="h-6 w-6 animate-spin rounded-full border-b-2 border-blue-600"></div>
          <span className="text-gray-600 ml-2">Loading products...</span>
        </div>
      </div>
    );
  }
  return (
    <div className="products-page">
      <div className="border-gray-200 rounded-lg border bg-white p-6">
        <h2 className="text-gray-900 mb-4 text-lg font-semibold">Products</h2>
        <div className="py-12 text-center">
          <div className="mb-4 text-4xl">📦</div>
          <h3 className="text-gray-900 mb-2 text-lg font-medium">Product Management</h3>
          <p className="text-gray-600 mb-4">Manage your digital products and sales</p>
          <div className="text-sm text-blue-600">🚧 Converting from server-side to SPA... Coming soon!</div>
        </div>
      </div>
    </div>
  );
};
