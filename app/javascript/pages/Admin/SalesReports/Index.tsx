import { usePage } from "@inertiajs/react";
import * as React from "react";

import AdminSalesReportsJobHistory, { type JobHistoryItem } from "$app/components/Admin/SalesReports/JobHistory";

type PageProps = {
  countries: [string, string][];
  sales_types: [string, string][];
  job_history: JobHistoryItem[];
  authenticity_token: string;
};

const AdminSalesReports = () => {
  const { countries, sales_types, job_history: jobHistory } = usePage<PageProps>().props;

  return <AdminSalesReportsJobHistory countries={countries} sales_types={sales_types} jobHistory={jobHistory} />;
};

export default AdminSalesReports;
