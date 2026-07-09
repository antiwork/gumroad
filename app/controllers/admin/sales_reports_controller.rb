# frozen_string_literal: true

class Admin::SalesReportsController < Admin::BaseController
  def index
    set_meta_tag(title: "Sales reports")

    render inertia: "Admin/SalesReports/Index", props: {
      countries: Compliance::Countries.for_select.map { |alpha2, name| [name, alpha2] },
      sales_types: GenerateSalesReportJob::SALES_TYPES.map { [_1, _1.humanize] },
      job_history: Admin::SalesReport.fetch_job_history
    }
  end

  def create
    sales_report = Admin::SalesReport.new(sales_report_params)
    if sales_report.valid?
      sales_report.generate_later
      redirect_to admin_sales_reports_path, status: :see_other, notice: "Sales report job enqueued successfully!"
    else
      redirect_to admin_sales_reports_path, inertia: inertia_errors(sales_report), alert: "Invalid form submission. Please fix the errors."
    end
  end

  private
    def sales_report_params
      params.require(:sales_report).permit(:country_code, :start_date, :end_date, :sales_type)
    end
end
