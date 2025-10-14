import * as React from "react";

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
      <table>
        <thead>
          <tr>
            <th>Country</th>
            <th>Date range</th>
            <th>Enqueued at</th>
            <th>Status</th>
            <th>Download</th>
          </tr>
        </thead>
        <tbody>
          {jobHistory.map((job, index) => (
            <tr key={index}>
              <td>{countryCodeToName[job.country_code] || job.country_code}</td>
              <td>
                {job.start_date} to {job.end_date}
              </td>
              <td>{new Date(job.enqueued_at).toLocaleString()}</td>
              <td>{job.status}</td>
              <td>
                {job.status === "completed" && job.download_url ? (
                  <a href={job.download_url} className="button small" target="_blank" rel="noopener noreferrer">
                    Download CSV
                  </a>
                ) : (
                  <span>-</span>
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
