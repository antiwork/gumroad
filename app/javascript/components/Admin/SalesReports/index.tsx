import * as React from "react";

import AdminSalesReportsForm from "$app/components/Admin/SalesReports/Form";
import AdminSalesReportsJobHistory, { type JobHistoryItem } from "$app/components/Admin/SalesReports/JobHistory";

type Props = {
  countries: [string, string][];
  jobHistory: JobHistoryItem[];
  authenticityToken: string;
};

const AdminSalesReports = ({ countries, jobHistory, authenticityToken }: Props) => (
  <>
    <AdminSalesReportsForm countries={countries} authenticityToken={authenticityToken} />
    <AdminSalesReportsJobHistory countries={countries} jobHistory={jobHistory} />
  </>
);

export default AdminSalesReports;
