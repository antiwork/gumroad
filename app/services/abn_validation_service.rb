# frozen_string_literal: true

class AbnValidationService
  attr_reader :abn_id

  def initialize(abn_id)
    @abn_id = abn_id
  end

  def process
    return false if abn_id.blank?

    response = Rails.cache.fetch("vatstack_validation_#{abn_id}", expires_in: 10.minutes) do
      url = "https://api.vatstack.com/v1/validations"
      headers = {
        "X-API-KEY" => VATSTACK_API_KEY
      }
      params = {
        type: "au_gst",
        query: abn_id
      }.stringify_keys

      HTTParty.post(url, body: params, timeout: 5, headers:)
    end

    return false if "INVALID_INPUT" == response["code"]
    return false if response["valid"].nil?

    response["valid"] && response["active"]
  end
end
