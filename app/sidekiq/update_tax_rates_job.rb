# frozen_string_literal: true

class UpdateTaxRatesJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform
    summary_rates = client.summary_rates

    summary_rates.select { |summary_rate|  Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(summary_rate.country_code) || tax_jar_country_codes_map[summary_rate.country_code].present? }.each do |summary_rate|
      next unless summary_rate.average_rate.rate > 0

      country_code = tax_jar_country_codes_map[summary_rate.country_code] || summary_rate.country_code

      zip_tax_rate = ZipTaxRate.not_is_epublication_rate.alive.where(country: country_code).first
      if zip_tax_rate
        if zip_tax_rate.combined_rate != summary_rate.average_rate.rate
          SlackMessageWorker.perform_async("payments", "VAT Rate Updater", "VAT rate has changed for #{country_code} from #{zip_tax_rate.combined_rate} to #{summary_rate.average_rate.rate}", "green")
          zip_tax_rate.combined_rate = summary_rate.average_rate.rate
          zip_tax_rate.save!
        end
      else
        SlackMessageWorker.perform_async("payments", "VAT Rate Updater", "Creating missing tax rate for #{country_code} with rate of #{summary_rate.average_rate.rate}", "green")
        zip_tax_rate = ZipTaxRate.not_is_epublication_rate.find_or_create_by(country: country_code)
        zip_tax_rate.update(combined_rate: summary_rate.average_rate.rate)
        # Make sure the tax rate was not in deleted state instead
        zip_tax_rate.mark_undeleted!
      end
    end

    summary_rates.select { |summary_rate| summary_rate.country_code == Compliance::Countries::USA.alpha2 }.each do |summary_rate|
      state = summary_rate.region_code
      next unless Compliance::Countries.taxable_state?(state)
      next unless summary_rate.average_rate.rate > 0

      zip_tax_rate = ZipTaxRate.alive
        .where(country: Compliance::Countries::USA.alpha2, state:, zip_code: nil)
        .not_is_epublication_rate
        .first

      is_seller_responsible = !Compliance::Countries.taxable_state?(state)

      if zip_tax_rate
        if zip_tax_rate.combined_rate != summary_rate.average_rate.rate || is_seller_responsible != zip_tax_rate.is_seller_responsible
          SlackMessageWorker.perform_async("payments", "VAT Rate Updater", "US Sales Tax rate for state #{state} has changed. Rate was #{zip_tax_rate.combined_rate}, now it's #{summary_rate.average_rate.rate}. is_seller_responsible was #{zip_tax_rate.is_seller_responsible}, now it's #{is_seller_responsible}", "green")
          zip_tax_rate.combined_rate = summary_rate.average_rate.rate
          zip_tax_rate.is_seller_responsible = is_seller_responsible
          zip_tax_rate.save!
        end
      else
        SlackMessageWorker.perform_async("payments", "VAT Rate Updater", "Creating US Sales Tax rate for state #{state} with rate of #{summary_rate.average_rate.rate} and is_seller_responsible #{is_seller_responsible}", "green")
        ZipTaxRate.create!(
          country: "US",
          state:,
          zip_code: nil,
          combined_rate: summary_rate.average_rate.rate,
          is_seller_responsible:
        )
      end
    end

    summary_rates.select { |summary_rate| summary_rate.country_code == Compliance::Countries::CAN.alpha2 }.each do |summary_rate|
      province = summary_rate.region_code
      next unless Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first).include?(province)

      zip_tax_rate = ZipTaxRate.alive
        .where(country: Compliance::Countries::CAN.alpha2, state: province)
        .not_is_epublication_rate
        .first

      if zip_tax_rate
        if zip_tax_rate.combined_rate != summary_rate.average_rate.rate
          SlackMessageWorker.perform_async("payments", "VAT Rate Updater", "Canada Sales Tax rate for province #{province} has changed. Rate was #{zip_tax_rate.combined_rate}, now it's #{summary_rate.average_rate.rate}.", "green")
          zip_tax_rate.combined_rate = summary_rate.average_rate.rate
          zip_tax_rate.save!
        end
      else
        SlackMessageWorker.perform_async("payments", "VAT Rate Updater", "Creating Canada Sales Tax rate for province #{province} with rate of #{summary_rate.average_rate.rate}", "green")
        ZipTaxRate.create!(
          country: "CA",
          state: province,
          zip_code: nil,
          combined_rate: summary_rate.average_rate.rate
        )
      end
    end
  end

  private
    def client
      @client ||= Taxjar::Client.new(api_key: TAXJAR_API_KEY, headers: { "x-api-version" => "2022-01-24" }, api_url: TAXJAR_ENDPOINT)
    end

    # TaxJar uses different county codes instead of sticking to ISO-3166-1
    def tax_jar_country_codes_map
      { "EL" => "GR", "UK" => "GB" }
    end
end
