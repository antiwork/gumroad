import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/server-components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";
import Placeholder from "$app/components/ui/Placeholder";

type JobHistoryItem = {
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
  job_history: JobHistoryItem[];
  form_action: string;
  authenticity_token: string;
};

const AdminSalesReportsPage = ({ countries, job_history, form_action, authenticity_token }: Props) => {
  const countryCodeToName = React.useMemo(() => {
    const map: Record<string, string> = {};
    countries.forEach(([name, code]) => {
      map[code] = name;
    });
    return map;
  }, [countries]);

  return (
    <>
      <Form
        url={form_action}
        method="POST"
        confirmMessage={false}
        onSuccess={() => {
          showAlert("Sales report job enqueued successfully!", "success");
          window.location.reload();
        }}
      >
        {(isLoading) => (
          <section>
            <header>Generate sales report with custom date ranges</header>

            <label htmlFor="country_code">Country</label>
            <select name="sales_report[country_code]" id="country_code" required>
              <option value="">Select country</option>
              {countries.map(([name, code]) => (
                <option key={code} value={code}>
                  {name}
                </option>
              ))}
            </select>

            <label htmlFor="start_date">Start date</label>
            <input name="sales_report[start_date]" id="start_date" type="date" required />

            <label htmlFor="end_date">End date</label>
            <input name="sales_report[end_date]" id="end_date" type="date" required />

            <button type="submit" className="button primary" disabled={isLoading}>
              {isLoading ? "Generating..." : "Generate report"}
            </button>

            <input type="hidden" name="authenticity_token" value={authenticity_token} />
          </section>
        )}
      </Form>

      <section>
        {job_history.length > 0 ? (
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
              {job_history.map((job, index) => (
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
        ) : (
          <Placeholder>
            <h2>No sales reports generated yet.</h2>
          </Placeholder>
        )}
      </section>
    </>
  );
};

export default register({ component: AdminSalesReportsPage, propParser: createCast() });
