# frozen_string_literal: true

if Rails.env.staging? || Rails.env.production?
  PDFKit.configure do |config|
    config.wkhtmltopdf = File.join("/", "usr", "local", "bin", "wkhtmltopdf")
  end
end
