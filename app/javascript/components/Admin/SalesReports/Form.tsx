import { useForm } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

type Props = {
  countries: [string, string][];
  authenticityToken: string;
};

type Errors = {
  authenticity_token?: string;
  sales_report?: {
    country_code?: string;
    start_date?: string;
    end_date?: string;
  };
};

const AdminSalesReportsForm = ({ countries, authenticityToken }: Props) => {
  const defaultStartDate = React.useMemo(() => {
    const date = new Date();
    date.setMonth(date.getMonth() - 1);
    return date.toISOString().split("T")[0];
  }, []);

  const defaultEndDate = React.useMemo(() => {
    const date = new Date();
    return date.toISOString().split("T")[0];
  }, []);

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
        {errors.sales_report?.country_code ? <p className="text-red">{errors.sales_report.country_code}</p> : null}

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
        {errors.sales_report?.start_date ? <p className="text-red">{errors.sales_report.start_date}</p> : null}

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
        {errors.sales_report?.end_date ? <p className="text-red">{errors.sales_report.end_date}</p> : null}

        <button type="submit" className="button primary" disabled={form.processing}>
          {form.processing ? "Generating..." : "Generate report"}
        </button>

        <input type="hidden" name="authenticity_token" value={form.data.authenticity_token} />
      </section>
    </form>
  );
};

export default AdminSalesReportsForm;
