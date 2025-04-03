# frozen_string_literal: true

class GstValidationService
  attr_reader :gst_id

  def initialize(gst_id)
    @gst_id = gst_id
  end

  def process
    return false if gst_id.blank?

    Rails.cache.fetch("iras_validation_#{gst_id}", expires_in: 10.minutes) do
      headers = {
        "X-IBM-Client-Id" => IRAS_API_ID,
        "X-IBM-Client-Secret" => IRAS_API_SECRET,
        "accept" => "application/json",
        "content-type" => "application/json"
      }
      body = {
        clientID: IRAS_API_ID,
        regID: gst_id
      }.to_json

      response = HTTParty.post(IRAS_ENDPOINT, body:, timeout: 5, headers:)

      response["returnCode"] == "10" && response["data"]["Status"] == "Registered"
    end
  end
end
