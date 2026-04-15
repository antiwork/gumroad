# frozen_string_literal: true

OPEN_EXCHANGE_RATES_API_BASE_URL = "https://openexchangerates.org/api"
OPEN_EXCHANGE_RATE_KEY           = GlobalConfig.get("OPEN_EXCHANGE_RATES_APP_ID")

CURRENCY_SOURCE = if Rails.env.development? || Rails.env.test?
  "#{Rails.root}/lib/currency/backup_rates.json"
else
  "#{OPEN_EXCHANGE_RATES_API_BASE_URL}/latest.json?app_id=#{OPEN_EXCHANGE_RATE_KEY}"
end

CURRENCY_CHOICES = HashWithIndifferentAccess.new(JSON.load_file("#{Rails.root}/config/currencies.json")["currencies"])
