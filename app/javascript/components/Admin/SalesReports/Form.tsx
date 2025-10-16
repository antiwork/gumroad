import { useForm } from "@inertiajs/react";
import { subMonths } from "date-fns";
import * as React from "react";
import { cast } from "ts-safe-cast";

import Errors from "$app/components/Admin/Form/Errors";

type Props = {
  countries: [string, string][];
  authenticityToken: string;
};

type Errors = {
  authenticity_token?: string[];
  sales_report?: {
    country_code?: string[];
    start_date?: string[];
    end_date?: string[];
  };
};

const AdminSalesReportsForm = ({ countries, authenticityToken }: Props) => {
  const defaultStartDate = React.useMemo(() => subMonths(new Date(), 1).toISOString().split("T")[0], []);
  const defaultEndDate = React.useMemo(() => new Date().toISOString().split("T")[0], []);

  const form = useForm({
    authenticity_token: authenticityToken,
    sales_report: {
      country_code: "",
      start_date: defaultStartDate,
      end_date: defaultEndDate,
    },
  });

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    form.post(Routes.admin_sales_reports_path(), {
      only: ["job_history", "errors", "flash"],
      onSuccess: () => form.resetAndClearErrors(),
    });
  };

  const errors = cast<Errors>(form.errors);

  return (
    <form onSubmit={handleSubmit}>
      <section>
        <header>Generate sales report with custom date ranges</header>

        <label htmlFor="country_code">Country</label>
        <select
          name="sales_report[country_code]"
          id="country_code"
          onChange={(event: React.ChangeEvent<HTMLSelectElement>) =>
            form.setData("sales_report.country_code", event.target.value)
          }
          value={form.data.sales_report.country_code}
          required
        >
          <option value="">Select country</option>
          {countries.map(([name, code]) => (
            <option key={code} value={code}>
              {name}
            </option>
          ))}
        </select>
        <Errors errors={errors.sales_report?.country_code} label="Country code" />

        <label htmlFor="start_date">Start date</label>
        <input
          name="sales_report[start_date]"
          id="start_date"
          type="date"
          required
          onChange={(event: React.ChangeEvent<HTMLInputElement>) =>
            form.setData("sales_report.start_date", event.target.value)
          }
          value={form.data.sales_report.start_date}
        />
        <Errors errors={errors.sales_report?.start_date} label="Start date" />

        <label htmlFor="end_date">End date</label>
        <input
          name="sales_report[end_date]"
          id="end_date"
          type="date"
          required
          onChange={(event: React.ChangeEvent<HTMLInputElement>) =>
            form.setData("sales_report.end_date", event.target.value)
          }
          value={form.data.sales_report.end_date}
        />
        <Errors errors={errors.sales_report?.end_date} label="End date" />

        <button type="submit" className="button primary" disabled={form.processing}>
          {form.processing ? "Generating..." : "Generate report"}
        </button>

        <input type="hidden" name="authenticity_token" value={form.data.authenticity_token} />
      </section>
    </form>
  );
};

export default AdminSalesReportsForm;
