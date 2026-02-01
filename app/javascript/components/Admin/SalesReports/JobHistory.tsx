import { usePoll } from "@inertiajs/react";
import * as React from "react";

import AdminSalesReportsForm from "$app/components/Admin/SalesReports/Form";
import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { FormSection } from "$app/components/ui/FormSection";
import { Placeholder } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

export type JobHistoryItem = {
  job_id: string;
  country_code: string;
  start_date: string;
  end_date: string;
  sales_type: string;
  enqueued_at: string;
  status: string;
  download_url?: string;
};

type Props = {
  countries: [string, string][];
  sales_types: [string, string][];
  jobHistory: JobHistoryItem[];
  authenticityToken: string;
};

const AdminSalesReportsJobHistory = ({ countries, sales_types, jobHistory, authenticityToken }: Props) => {
  const [showNewSalesReportForm, setShowNewSalesReportForm] = React.useState(false);

  const hasProcessingJobs = jobHistory.some((job) => job.status === "processing");

  const { start, stop } = usePoll(3000, { only: ["job_history"] }, { autoStart: false });

  React.useEffect(() => {
    if (hasProcessingJobs) start();
    else stop();
  }, [hasProcessingJobs]);

  const countryCodeToName = React.useMemo(() => {
    const map: Record<string, string> = {};
    countries.forEach(([name, code]) => {
      map[code] = name;
    });
    return map;
  }, [countries]);

  const salesTypeCodeToName = React.useMemo(() => {
    const map: Record<string, string> = {};
    sales_types.forEach(([code, name]) => {
      map[code] = name;
    });
    return map;
  }, [sales_types]);

  if (jobHistory.length === 0) {
    return showNewSalesReportForm ? (
      <AdminSalesReportsForm
        countries={countries}
        sales_types={sales_types}
        authenticityToken={authenticityToken}
        onSuccess={() => setShowNewSalesReportForm(false)}
        wrapper={(children) => (
          <FormSection className="p-4 md:p-8" header="Generate sales report with custom date ranges">
            {children}
          </FormSection>
        )}
      />
    ) : (
      <section>
        <Placeholder>
          <h2>Generate your first sales report</h2>
          Create a report to view sales data by country for a specified date range.
          <Button color="primary" onClick={() => setShowNewSalesReportForm(true)}>
            <Icon name="plus" />
            New report
          </Button>
        </Placeholder>
      </section>
    );
  }

  return (
    <section>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Country</TableHead>
            <TableHead>Date range</TableHead>
            <TableHead>Type of sales</TableHead>
            <TableHead>Enqueued at</TableHead>
            <TableHead>Download</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {jobHistory.map((job, index) => (
            <TableRow key={index}>
              <TableCell>{countryCodeToName[job.country_code] || job.country_code}</TableCell>
              <TableCell>
                {job.start_date} - {job.end_date}
              </TableCell>
              <TableCell>{job.sales_type ? salesTypeCodeToName[job.sales_type] : sales_types[0]?.[1]}</TableCell>
              <TableCell>{new Date(job.enqueued_at).toLocaleString()}</TableCell>
              <TableCell>
                {job.status === "completed" && job.download_url ? (
                  <a href={job.download_url} target="_blank" rel="noopener noreferrer">
                    <div className="grid grid-cols-[auto_1fr] gap-2">
                      <Icon name="download" />
                      {countryCodeToName[job.country_code]}_{job.sales_type}_report_{job.start_date}_{job.end_date}
                    </div>
                  </a>
                ) : (
                  <div className="grid grid-cols-[auto_1fr] items-center gap-2">
                    <LoadingSpinner />
                    <span>Processing</span>
                  </div>
                )}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </section>
  );
};

export default AdminSalesReportsJobHistory;
