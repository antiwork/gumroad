import { ArrowInDownSquareHalf, Plus, RefreshCw } from "@boxicons/react";
import { router, usePoll } from "@inertiajs/react";
import * as React from "react";

import AdminSalesReportsForm from "$app/components/Admin/SalesReports/Form";
import { Button } from "$app/components/Button";
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
  status: "processing" | "completed" | "failed";
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
  // Tracks which failed row's re-run request is in flight, so its button can
  // disable immediately instead of allowing accidental double-enqueues while
  // the new "processing" entry is still on its way back from the server.
  const [rerunningJobId, setRerunningJobId] = React.useState<string | null>(null);

  const rerunReport = (job: JobHistoryItem) => {
    setRerunningJobId(job.job_id);
    // Re-runs in place: the server swaps this row back to "processing" with a
    // fresh job ID instead of prepending a duplicate history entry.
    router.post(
      Routes.rerun_admin_sales_report_path(job.job_id),
      { authenticity_token: authenticityToken },
      {
        only: ["job_history", "errors", "flash"],
        onFinish: () => setRerunningJobId(null),
      },
    );
  };

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
          <FormSection header="Generate sales report with custom date ranges">{children}</FormSection>
        )}
      />
    ) : (
      <section>
        <Placeholder>
          <h2>Generate your first sales report</h2>
          Create a report to view sales data by country for a specified date range.
          <Button color="primary" onClick={() => setShowNewSalesReportForm(true)}>
            <Plus className="size-5" />
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
                      <ArrowInDownSquareHalf className="size-5" />
                      {countryCodeToName[job.country_code]}_{job.sales_type}_report_{job.start_date}_{job.end_date}
                    </div>
                  </a>
                ) : job.status === "failed" ? (
                  <div className="grid grid-cols-[1fr_auto] items-center gap-2">
                    <span className="text-red">Failed</span>
                    <Button size="sm" onClick={() => rerunReport(job)} disabled={rerunningJobId === job.job_id}>
                      <RefreshCw className="size-4" />
                      Re-run
                    </Button>
                  </div>
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
