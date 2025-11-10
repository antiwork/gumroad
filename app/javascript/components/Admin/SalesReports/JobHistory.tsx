import * as React from "react";

import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

export type JobHistoryItem = {
  job_id: string;
  country_code: string;
  start_date: string;
  end_date: string;
  enqueued_at: string;
  status: string;
  download_url?: string;
};

type Props = {
  countries: [string, string][];
  jobHistory: JobHistoryItem[];
};

const AdminSalesReportsJobHistory = ({ countries, jobHistory }: Props) => {
  if (jobHistory.length === 0) {
    return (
      <section>
        <div className="placeholder">
          <h2>No sales reports generated yet.</h2>
        </div>
      </section>
    );
  }

  const countryCodeToName = React.useMemo(() => {
    const map: Record<string, string> = {};
    countries.forEach(([name, code]) => {
      map[code] = name;
    });
    return map;
  }, [countries]);

  return (
    <section>
      <Table>
        <TableCaption>Job History</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead>Country</TableHead>
            <TableHead>Date range</TableHead>
            <TableHead>Enqueued at</TableHead>
            <TableHead>Status</TableHead>
            <TableHead>Download</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {jobHistory.map((job, index) => (
            <TableRow key={index}>
              <TableCell label="Country">{countryCodeToName[job.country_code] || job.country_code}</TableCell>
              <TableCell label="Date range">
                {job.start_date} to {job.end_date}
              </TableCell>
              <TableCell label="Enqueued at">{new Date(job.enqueued_at).toLocaleString()}</TableCell>
              <TableCell label="Status">{job.status}</TableCell>
              <TableCell label="Download">
                {job.status === "completed" && job.download_url ? (
                  <a href={job.download_url} className="button small" target="_blank" rel="noopener noreferrer">
                    Download CSV
                  </a>
                ) : (
                  <span>-</span>
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
