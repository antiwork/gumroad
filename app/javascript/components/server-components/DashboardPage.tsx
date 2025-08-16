import React from "react";

interface DashboardPageProps {
  user_name?: string;
  stats?: {
    revenue?: number;
    sales?: number;
    products?: number;
  };
  [key: string]: any;
}

const DashboardPage: React.FC<DashboardPageProps> = (props) => {
  const { user_name, stats = {} } = props;
  
  return (
    <div className="dashboard-home">
      {/* Welcome Section */}
      <div className="mb-8">
        <h1 className="text-3xl font-bold text-gray-900 mb-2">
          {user_name ? `Welcome back, ${user_name}!` : 'Welcome to your Dashboard'}
        </h1>
        <p className="text-gray-600">Here's what's happening with your business</p>
      </div>

      {/* Stats Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
        <div className="bg-white p-6 rounded-lg border border-gray-200 shadow-sm">
          <h3 className="text-sm font-medium text-gray-500 mb-2">Total Revenue</h3>
          <p className="text-3xl font-bold text-gray-900">${(stats.revenue || 0).toLocaleString()}</p>
          <p className="text-sm text-green-600 mt-1">↗ Growing</p>
        </div>
        
        <div className="bg-white p-6 rounded-lg border border-gray-200 shadow-sm">
          <h3 className="text-sm font-medium text-gray-500 mb-2">Total Sales</h3>
          <p className="text-3xl font-bold text-gray-900">{stats.sales || 0}</p>
          <p className="text-sm text-blue-600 mt-1">← View analytics</p>
        </div>
        
        <div className="bg-white p-6 rounded-lg border border-gray-200 shadow-sm">
          <h3 className="text-sm font-medium text-gray-500 mb-2">Products</h3>
          <p className="text-3xl font-bold text-gray-900">{stats.products || 0}</p>
          <p className="text-sm text-purple-600 mt-1">→ Manage products</p>
        </div>
        
        <div className="bg-white p-6 rounded-lg border border-gray-200 shadow-sm">
          <h3 className="text-sm font-medium text-gray-500 mb-2">Conversion Rate</h3>
          <p className="text-3xl font-bold text-gray-900">3.2%</p>
          <p className="text-sm text-orange-600 mt-1">↑ +0.5% this week</p>
        </div>
      </div>

      {/* Quick Actions */}
      <div className="bg-white rounded-lg border border-gray-200 p-6">
        <h2 className="text-xl font-semibold text-gray-900 mb-4">Quick Actions</h2>
        <div className="flex flex-wrap gap-4">
          <button className="px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors font-medium">
            🆕 Create New Product
          </button>
          <button className="px-6 py-3 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors font-medium">
            📊 View Analytics
          </button>
          <button className="px-6 py-3 bg-purple-600 text-white rounded-lg hover:bg-purple-700 transition-colors font-medium">
            👥 Check Audience
          </button>
          <button className="px-6 py-3 bg-orange-600 text-white rounded-lg hover:bg-orange-700 transition-colors font-medium">
            🔗 Create UTM Link
          </button>
        </div>
      </div>

      {/* SPA Migration Notice */}
      <div className="mt-8 bg-blue-50 border border-blue-200 rounded-lg p-4">
        <div className="flex items-center">
          <div className="text-blue-600 mr-3">🚀</div>
          <div>
            <h3 className="text-sm font-medium text-blue-900">SPA Migration in Progress</h3>
            <p className="text-sm text-blue-700 mt-1">
              This dashboard is being converted to a Single Page Application for better performance. 
              Click the links above to experience the new SPA navigation!
            </p>
          </div>
        </div>
      </div>
    </div>
  );
};

export { DashboardPage };
export default DashboardPage;