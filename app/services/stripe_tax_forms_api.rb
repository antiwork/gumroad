# frozen_string_literal: true

class StripeTaxFormsApi
  include HTTParty

  def initialize(stripe_account_id:, form_type:, year:)
    @stripe_account_id = stripe_account_id
    @form_type = form_type
    @year = year
  end

  def download_tax_form
    tax_form = tax_forms_by_year[year]
    return if tax_form.nil?

    pdf = Tempfile.new(["tax_form_#{form_type}_#{year}_#{stripe_account_id}", ".pdf"])
    pdf.binmode
    url = "https://files.stripe.com/v1/tax/forms/#{tax_form.id}/pdf"
    headers = { "Authorization" => "Bearer #{Stripe.api_key}", "Stripe-Version" => "2022-11-15; retrieve_tax_forms_beta=v1;" }

    HTTParty.get(url, headers:, stream_body: true) do |fragment|
      pdf.write(fragment)
    end
    pdf.rewind

    pdf
  rescue HTTParty::Error => e
    Bugsnag.notify(e)
    nil
  end

  def tax_forms_by_year
    raise "Invalid tax form type: #{form_type}" unless UserTaxForm::TAX_FORM_TYPES.include?(form_type)

    Rails.cache.fetch("stripe_tax_forms_#{form_type}_#{stripe_account_id}", expires_in: 1.day) do
      params = { type: form_type, "payee[account]": stripe_account_id }
      opts = { stripe_version: Stripe.api_version }

      tax_forms = {}
      response = Stripe.raw_request(:get, "/v1/tax/forms", params, opts)
      Stripe.deserialize(response.http_body).auto_paging_each do |tax_form|
        year = tax_form[tax_form.type].reporting_year
        tax_forms[year] = tax_form
      end

      tax_forms
    end
  rescue Stripe::StripeError => e
    Bugsnag.notify(e)
    {}
  end

  private
    attr_reader :stripe_account_id, :form_type, :year
end
