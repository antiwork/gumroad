# frozen_string_literal: true

class Api::V2::TaxFormsController < Api::V2::BaseController
  include Api::V2::TaxCenterAccess

  def index
    forms = current_resource_owner.user_tax_forms.order(:tax_year, :tax_form_type)

    if params[:year].present?
      year = parse_year_param
      return render_year_not_available(year, "Tax forms") unless valid_tax_year?(year)
      forms = forms.for_year(year)
    end

    render_response(true, tax_forms: forms.map { |form| serialize_tax_form(form) })
  end

  def download
    year = parse_year_param
    tax_form_type = params[:tax_form_type]

    return render_form_not_found unless valid_tax_year?(year)
    return render_form_not_found unless tax_form_type.is_a?(String) && UserTaxForm::TAX_FORM_TYPES.include?(tax_form_type)

    tax_form = current_resource_owner.user_tax_forms.for_year(year).where(tax_form_type:).first
    return render_form_not_found if tax_form.blank?

    stripe_account_id = tax_form.stripe_account_id || current_resource_owner.stripe_account&.charge_processor_merchant_id
    if stripe_account_id && !current_resource_owner.merchant_accounts.stripe.exists?(charge_processor_merchant_id: stripe_account_id)
      return render_form_not_found
    end

    filename = "#{tax_form_type.delete_prefix('us_').tr('_', '-').upcase}-#{year}.pdf"

    pdf_tempfile = StripeTaxFormsApi.new(stripe_account_id:, form_type: tax_form_type, year:).download_tax_form

    if pdf_tempfile
      send_file pdf_tempfile.path, filename:, type: "application/pdf", disposition: "attachment"
      pdf_tempfile.close
      return
    end

    if tax_form_type == "us_1099_k" && (pdf_bytes = current_resource_owner.tax_form_1099_s3_bytes(year:))
      send_data pdf_bytes, filename:, type: "application/pdf", disposition: "attachment"
      return
    end

    render_form_not_found
  end

  private
    def serialize_tax_form(form)
      {
        tax_year: form.tax_year,
        tax_form_type: form.tax_form_type,
        filed_at: form.filed? ? Time.at(form.filed_at).utc.iso8601 : nil
      }
    end

    def render_form_not_found
      render status: :not_found, json: { success: false, message: "Tax form not found." }
    end
end
