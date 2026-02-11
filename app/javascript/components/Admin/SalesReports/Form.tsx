import { useForm } from "@inertiajs/react";
import { subMonths } from "date-fns";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { classNames } from "$app/utils/classNames";

import { Button } from "$app/components/Button";
import Errors from "$app/components/Form/Errors";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";

type Props = {
  countries: [string, string][];
  sales_types: [string, string][];
  authenticityToken: string;
  onSuccess?: () => void;
  wrapper?: (children: React.ReactNode) => React.ReactNode;
};

type Errors = {
  authenticity_token?: string[];
  "sales_report.country_code"?: string | undefined;
  "sales_report.start_date"?: string | undefined;
  "sales_report.end_date"?: string | undefined;
  "sales_report.sales_type"?: string | undefined;
};

const AdminSalesReportsForm = ({
  countries,
  sales_types,
  authenticityToken,
  onSuccess,
  wrapper = (children) => children,
}: Props) => {
  const defaultStartDate = React.useMemo(() => subMonths(new Date(), 1).toISOString().split("T")[0], []);
  const defaultEndDate = React.useMemo(() => new Date().toISOString().split("T")[0], []);

  const form = useForm({
    authenticity_token: authenticityToken,
    sales_report: {
      country_code: "",
      start_date: defaultStartDate,
      end_date: defaultEndDate,
      sales_type: sales_types[0]?.[0],
    },
  });

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    form.post(Routes.admin_sales_reports_path(), {
      only: ["job_history", "errors", "flash"],
      onSuccess: () => {
        form.resetAndClearErrors();
        onSuccess?.();
      },
    });
  };

  const errors = cast<Errors>(form.errors);

  return (
    <form onSubmit={handleSubmit}>
      {wrapper(
        <>
          <Fieldset
            className={classNames("grid grid-rows-[auto_1fr] gap-3", {
              danger: !!errors["sales_report.country_code"]?.length,
            })}
          >
            <FieldsetTitle>
              <Label htmlFor="country_code">Country</Label>
            </FieldsetTitle>
            <Select
              name="sales_report[country_code]"
              id="country_code"
              onChange={(event: React.ChangeEvent<HTMLSelectElement>) =>
                form.setData("sales_report.country_code", event.target.value)
              }
              value={form.data.sales_report.country_code}
              required
              aria-invalid={!!errors["sales_report.country_code"]?.length}
            >
              <option value="">Select country</option>
              {countries.map(([name, code]) => (
                <option key={code} value={code}>
                  {name}
                </option>
              ))}
            </Select>
            <Errors errors={errors["sales_report.country_code"]} label="Country code" />
          </Fieldset>

          <div className="grid grid-cols-2 gap-3">
            <Fieldset
              className={classNames("grid grid-rows-[auto_1fr] gap-3", {
                danger: !!errors["sales_report.start_date"]?.length,
              })}
            >
              <FieldsetTitle>
                <Label htmlFor="start_date">Start date</Label>
              </FieldsetTitle>
              <Input
                name="sales_report[start_date]"
                id="start_date"
                type="date"
                required
                onChange={(event: React.ChangeEvent<HTMLInputElement>) =>
                  form.setData("sales_report.start_date", event.target.value)
                }
                value={form.data.sales_report.start_date}
                aria-invalid={!!errors["sales_report.start_date"]?.length}
              />
              <Errors errors={errors["sales_report.start_date"]} label="Start date" />
            </Fieldset>

            <Fieldset
              className={classNames("grid grid-rows-[auto_1fr] gap-3", {
                danger: !!errors["sales_report.end_date"]?.length,
              })}
            >
              <FieldsetTitle>
                <Label htmlFor="end_date">End date</Label>
              </FieldsetTitle>
              <Input
                name="sales_report[end_date]"
                id="end_date"
                type="date"
                required
                onChange={(event: React.ChangeEvent<HTMLInputElement>) =>
                  form.setData("sales_report.end_date", event.target.value)
                }
                value={form.data.sales_report.end_date}
                aria-invalid={!!errors["sales_report.end_date"]?.length}
              />
              <Errors errors={errors["sales_report.end_date"]} label="End date" />
            </Fieldset>
          </div>

          <Fieldset
            className={classNames("grid grid-rows-[auto_1fr] gap-3", {
              danger: !!errors["sales_report.sales_type"]?.length,
            })}
          >
            <FieldsetTitle>
              <Label htmlFor="sales_type">Type of sales</Label>
            </FieldsetTitle>
            <Select
              name="sales_report[sales_type]"
              id="sales_type"
              onChange={(event: React.ChangeEvent<HTMLSelectElement>) =>
                form.setData("sales_report.sales_type", event.target.value)
              }
              value={form.data.sales_report.sales_type}
              required
              aria-invalid={!!errors["sales_report.sales_type"]?.length}
            >
              {sales_types.map(([code, name]) => (
                <option key={code} value={code}>
                  {name}
                </option>
              ))}
            </Select>
            <Errors errors={errors["sales_report.sales_type"]} label="Type of sales" />
          </Fieldset>

          <Button type="submit" color="primary" disabled={form.processing}>
            {form.processing ? "Generating..." : "Generate report"}
          </Button>
        </>,
      )}
    </form>
  );
};

export default AdminSalesReportsForm;
