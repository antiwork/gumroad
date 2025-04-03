# frozen_string_literal: true

class MvaValidationService
  attr_reader :mva_id

  def initialize(mva_id)
    @mva_id = mva_id
  end

  def process
    return false if mva_id.blank?

    response = Rails.cache.fetch("vatstack_validation_#{mva_id}", expires_in: 10.minutes) do
      url = "https://api.vatstack.com/v1/validations"
      headers = {
        "X-API-KEY" => VATSTACK_API_KEY
      }
      params = {
        type: "no_vat",
        query: mva_id
      }.stringify_keys

      HTTParty.post(url, body: params, timeout: 5, headers:)
    end

    return false if "INVALID_INPUT" == response["code"]
    return false if response["valid"].nil?

    response["valid"] && response["active"]
  end
end
