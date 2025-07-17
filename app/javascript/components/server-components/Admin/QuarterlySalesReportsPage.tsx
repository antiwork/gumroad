import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Form } from "$app/components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

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
  title: string;
  countries: [string, string][];
  job_history: JobHistoryItem[];
  form_action: string;
  authenticity_token: string;
};

const AdminQuarterlySalesReportsPage = ({ title, countries, job_history, form_action, authenticity_token }: Props) => (
  <div className="paragraphs">
    <div className="card">
      <div className="paragraphs">
        <header>
          <h2>{title}</h2>
        </header>

        <Form
          url={form_action}
          method="POST"
          confirmMessage={false}
          onSuccess={() => showAlert("Sales report job enqueued successfully!", "success")}
        >
          {(isLoading) => (
            <section>
              <header>Enqueue sales report jobs with custom date ranges</header>

              <fieldset>
                <legend>
                  <label htmlFor="country_code">Country</label>
                </legend>
                <select name="quarterly_sales_report[country_code]" id="country_code" required>
                  <option value="">Select country</option>
                  {countries.map(([name, code]) => (
                    <option key={code} value={code}>
                      {name}
                    </option>
                  ))}
                </select>
              </fieldset>

              <fieldset>
                <legend>
                  <label htmlFor="start_date">Start date</label>
                </legend>
                <input name="quarterly_sales_report[start_date]" id="start_date" type="date" required />
              </fieldset>

              <fieldset>
                <legend>
                  <label htmlFor="end_date">End date</label>
                </legend>
                <input name="quarterly_sales_report[end_date]" id="end_date" type="date" required />
              </fieldset>

              <button type="submit" className="button primary" disabled={isLoading}>
                {isLoading ? "Enqueueing..." : "Enqueue report job"}
              </button>

              <input type="hidden" name="authenticity_token" value={authenticity_token} />
            </section>
          )}
        </Form>
      </div>
    </div>

    <div className="card">
      <div className="paragraphs">
        <header>Job history (last 20)</header>
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
                  <td>{job.country_code}</td>
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
          <div className="placeholder">
            <h2>No jobs enqueued yet.</h2>
          </div>
        )}
      </div>
    </div>
  </div>
);

export default register({ component: AdminQuarterlySalesReportsPage, propParser: createCast() });
