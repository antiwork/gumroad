import { usePage } from "@inertiajs/react";
import * as React from "react";

import AdminSalesReports from "$app/components/Admin/SalesReports";
import { type JobHistoryItem } from "$app/components/Admin/SalesReports/JobHistory";

type PageProps = {
  countries: [string, string][];
  job_history: JobHistoryItem[];
  authenticity_token: string;
};

const AdminSalesReportsPage = () => {
  const { countries, job_history: jobHistory, authenticity_token: authenticityToken } = usePage<PageProps>().props;

  return <AdminSalesReports countries={countries} jobHistory={jobHistory} authenticityToken={authenticityToken} />;
};

export default AdminSalesReportsPage;
