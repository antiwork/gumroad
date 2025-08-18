import React, { useEffect } from "react";
import { Routes, Route, useLocation } from "react-router-dom";
import { useDashboardAPI } from "$app/services/api/dashboardAPI";
import { useDashboardState } from "$app/services/state/dashboardStore";
import { PageLoading } from "../shared/LoadingStates";
import { ErrorFallback } from "../shared/ErrorBoundary";

// Import existing products components
import { ProductsDashboardPage } from "$app/components/server-components/ProductsDashboardPage";

const ProductsRoute: React.FC = () => {
  const location = useLocation();
  const { fetchProductsData, isLoading, getError } = useDashboardAPI();
  const state = useDashboardState();

  // Extract page from URL params or default to 1
  const searchParams = new URLSearchParams(location.search);
  const pageParam = Number(searchParams.get("page"));
  const currentPage =
    Number.isFinite(pageParam) && pageParam > 0 ? Math.floor(pageParam) : 1;

  useEffect(() => {
    fetchProductsData(currentPage);
  }, [fetchProductsData, currentPage]);

  const productsData = state.cache[`products_${currentPage}`];
  const isLoadingProducts = isLoading(`products_${currentPage}`);
  const error = getError(`products_${currentPage}`);

  if (error) {
    return <ErrorFallback error={new Error(error)} />;
  }

  if (isLoadingProducts && !productsData) {
    return <PageLoading message="Loading products..." />;
  }

  if (productsData) {
    return (
      <Routes>
        <Route 
          index 
          element={<ProductsDashboardPage {...productsData} />} 
        />
        {/* Add other product routes here if needed */}
        <Route 
          path="*" 
          element={<ProductsDashboardPage {...productsData} />} 
        />
      </Routes>
    );
  }

  return <PageLoading message="Loading products..." />;
};

export default ProductsRoute;