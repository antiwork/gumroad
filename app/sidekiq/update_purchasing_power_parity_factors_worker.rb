# frozen_string_literal: true

class UpdatePurchasingPowerParityFactorsWorker
  include Sidekiq::Job
  include CurrencyHelper

  API_URL = "https://api.worldbank.org/v2/en/indicator/PA.NUS.PPP?downloadformat=csv"
  API_FILE_PREFIX = "API_PA"
  UPPER_THRESHOLD = 0.8
  LOWER_THRESHOLD = 0.4

  sidekiq_options retry: 5, queue: :low

  def perform
    csv_zip = URI.open(API_URL).read
    ppp_service = PurchasingPowerParityService.new
    Zip::File.open_buffer(csv_zip) do |zip|
      zip.find { |entry| entry.name.start_with?(API_FILE_PREFIX) }.get_input_stream do |io|
        # The first four lines include irrelevant metadata that break the parsing
        csv = CSV.new(io.readlines[4..].join, headers: true)
        year = Integer(csv.read.headers.second_to_last, exception: false)
        raise "Couldn't determine correct year" if year.nil? || (year - Date.current.year).abs > 2
        csv.rewind

        csv.each do |ppp_data|
          country = ISO3166::Country.find_country_by_alpha3(ppp_data["Country Code"])
          next if country.blank?

          ppp_rate = (ppp_data[year.to_s].presence || 1).to_f
          exchange_rate = get_rate(country.currency_code).to_f
          next if exchange_rate.blank?

          ppp_factor = (ppp_rate / exchange_rate).round(2)
          ppp_factor = 1 if ppp_factor > UPPER_THRESHOLD
          ppp_factor = LOWER_THRESHOLD if ppp_factor < LOWER_THRESHOLD

          ppp_service.set_factor(country.alpha2, ppp_factor)
        end
      end
    end
  end
end
