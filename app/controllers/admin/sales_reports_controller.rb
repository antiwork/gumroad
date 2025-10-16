# frozen_string_literal: true

class Admin::SalesReportsController < Admin::BaseController
  def index
    @title = "Sales reports"

    render inertia: "Admin/SalesReports/Index", props: {
      countries: Compliance::Countries.for_select.map { |alpha2, name| [name, alpha2] },
      job_history: Admin::SalesReport.fetch_job_history
    }
  end

  def create
    sales_report = Admin::SalesReport.new(sales_report_params)
    if sales_report.valid?
      sales_report.generate_later
      redirect_to admin_sales_reports_path, status: :see_other, notice: "Sales report job enqueued successfully!"
    else
      redirect_to admin_sales_reports_path, inertia: { errors: sales_report.errors_hash }, alert: "Invalid form submission. Please fix the errors."
    end
  end

  private
    def sales_report_params
      params.require(:sales_report).permit(:country_code, :start_date, :end_date)
    end
end
