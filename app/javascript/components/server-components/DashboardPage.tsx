import React from "react";

interface DashboardPageProps {
  user_name?: string;
  stats?: {
    revenue?: number;
    sales?: number;
    products?: number;
  };
  [key: string]: unknown;
}

const DashboardPage: React.FC<DashboardPageProps> = (props) => {
  const { user_name, stats = {} } = props;

  return (
    <div className="dashboard-home">
      {/* Welcome Section */}
      <div className="mb-8">
        <h1 className="text-gray-900 mb-2 text-3xl font-bold">
          {user_name ? `Welcome back, ${user_name}!` : "Welcome to your Dashboard"}
        </h1>
        <p className="text-gray-600">Here's what's happening with your business</p>
      </div>

      {/* Stats Grid */}
      <div className="mb-8 grid grid-cols-1 gap-6 md:grid-cols-2 lg:grid-cols-4">
        <div className="border-gray-200 rounded-lg border bg-white p-6 shadow-sm">
          <h3 className="text-gray-500 mb-2 text-sm font-medium">Total Revenue</h3>
          <p className="text-gray-900 text-3xl font-bold">${(stats.revenue || 0).toLocaleString()}</p>
          <p className="text-green-600 mt-1 text-sm">↗ Growing</p>
        </div>

        <div className="border-gray-200 rounded-lg border bg-white p-6 shadow-sm">
          <h3 className="text-gray-500 mb-2 text-sm font-medium">Total Sales</h3>
          <p className="text-gray-900 text-3xl font-bold">{stats.sales || 0}</p>
          <p className="mt-1 text-sm text-blue-600">← View analytics</p>
        </div>

        <div className="border-gray-200 rounded-lg border bg-white p-6 shadow-sm">
          <h3 className="text-gray-500 mb-2 text-sm font-medium">Products</h3>
          <p className="text-gray-900 text-3xl font-bold">{stats.products || 0}</p>
          <p className="text-purple-600 mt-1 text-sm">→ Manage products</p>
        </div>

        <div className="border-gray-200 rounded-lg border bg-white p-6 shadow-sm">
          <h3 className="text-gray-500 mb-2 text-sm font-medium">Conversion Rate</h3>
          <p className="text-gray-900 text-3xl font-bold">3.2%</p>
          <p className="text-orange-600 mt-1 text-sm">↑ +0.5% this week</p>
        </div>
      </div>

      {/* Quick Actions */}
      <div className="border-gray-200 rounded-lg border bg-white p-6">
        <h2 className="text-gray-900 mb-4 text-xl font-semibold">Quick Actions</h2>
        <div className="flex flex-wrap gap-4">
          <button className="rounded-lg bg-blue-600 px-6 py-3 font-medium text-white transition-colors hover:bg-blue-700">
            🆕 Create New Product
          </button>
          <button className="bg-green-600 hover:bg-green-700 rounded-lg px-6 py-3 font-medium text-white transition-colors">
            📊 View Analytics
          </button>
          <button className="bg-purple-600 hover:bg-purple-700 rounded-lg px-6 py-3 font-medium text-white transition-colors">
            👥 Check Audience
          </button>
          <button className="bg-orange-600 hover:bg-orange-700 rounded-lg px-6 py-3 font-medium text-white transition-colors">
            🔗 Create UTM Link
          </button>
        </div>
      </div>

      {/* SPA Migration Notice */}
      <div className="mt-8 rounded-lg border border-blue-200 bg-blue-50 p-4">
        <div className="flex items-center">
          <div className="mr-3 text-blue-600">🚀</div>
          <div>
            <h3 className="text-sm font-medium text-blue-900">SPA Migration in Progress</h3>
            <p className="mt-1 text-sm text-blue-700">
              This dashboard is being converted to a Single Page Application for better performance. Click the links
              above to experience the new SPA navigation!
            </p>
          </div>
        </div>
      </div>
    </div>
  );
};

export { DashboardPage };
export default DashboardPage;
