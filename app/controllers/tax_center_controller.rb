# frozen_string_literal: true

class TaxCenterController < Sellers::BaseController
  layout "inertia", only: [:index]
  before_action :ensure_tax_center_enabled

  def index
    authorize :balance

    set_meta_tag(title: "Payouts")
    year = params[:year]&.to_i || Time.current.year - 1

    tax_center_presenter = TaxCenterPresenter.new(seller: current_seller, year:)

    render inertia: "TaxCenter/Index", props: tax_center_presenter.props
  end

  def download
    authorize :balance, :index?

    year = params[:year].to_i
    form_type = params[:form_type]

    error_message = "Tax form not available for download."

    tax_form = current_seller.user_tax_forms.for_year(year).where(tax_form_type: form_type).first
    if tax_form.blank?
      redirect_to tax_center_path(year:), alert: error_message
      return
    end

    stripe_account_id = tax_form.stripe_account_id || current_seller.stripe_account&.charge_processor_merchant_id
    if stripe_account_id && !current_seller.merchant_accounts.stripe.exists?(charge_processor_merchant_id: stripe_account_id)
      redirect_to tax_center_path(year:), alert: error_message
      return
    end

    pdf_tempfile = StripeTaxFormsApi.new(stripe_account_id:, form_type:, year:).download_tax_form

    if pdf_tempfile
      filename = "#{form_type.delete_prefix('us_').tr('_', '-').upcase}-#{year}.pdf"
      send_file pdf_tempfile.path, filename:, type: "application/pdf", disposition: "attachment"
      pdf_tempfile.close
    else
      redirect_to tax_center_path(year:), alert: error_message
    end
  end

  private
    def ensure_tax_center_enabled
      return if Feature.active?(:tax_center, current_seller)

      redirect_to dashboard_path, alert: "Tax center is not enabled for your account."
    end
end
