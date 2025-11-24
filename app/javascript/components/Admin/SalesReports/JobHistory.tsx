import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import Placeholder from "$app/components/ui/Placeholder";

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
};

const AdminSalesReportsJobHistory = ({ countries, sales_types, jobHistory }: Props) => {
  if (jobHistory.length === 0) {
    return (
      <section>
        <Placeholder>
          <h2>Generate your first sales report</h2>
          Create a report to view sales data by country for a specified date range.
          <Button color="primary">
            <Icon name="plus" />
            New report
          </Button>
        </Placeholder>
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

  const salesTypeCodeToName = React.useMemo(() => {
    const map: Record<string, string> = {};
    sales_types.forEach(([code, name]) => {
      map[code] = name;
    });
    return map;
  }, [sales_types]);

  return (
    <section>
      <table>
        <thead>
          <tr>
            <th>Country</th>
            <th>Date range</th>
            <th>Type of sales</th>
            <th>Generated at</th>
            <th>Download</th>
          </tr>
        </thead>
        <tbody>
          {jobHistory.map((job, index) => (
            <tr key={index}>
              <td>{countryCodeToName[job.country_code] || job.country_code}</td>
              <td>
                {job.start_date} - {job.end_date}
              </td>
              <td>{job.sales_type ? salesTypeCodeToName[job.sales_type] : sales_types[0]?.[1]}</td>
              <td>{new Date(job.enqueued_at).toLocaleString()}</td>
              <td>
                {job.status === "completed" && job.download_url ? (
                  <a href={job.download_url} target="_blank" rel="noopener noreferrer">
                    <div className="grid grid-cols-[auto_1fr] gap-2">
                      <Icon name="download" />
                      {countryCodeToName[job.country_code]}_{job.sales_type}_report_{job.start_date}_{job.end_date}
                    </div>
                  </a>
                ) : (
                  <div className="grid grid-cols-[auto_1fr] gap-2">
                    <Icon name="circle" />
                    <span>Processing</span>
                  </div>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
};

export default AdminSalesReportsJobHistory;
