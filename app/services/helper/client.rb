# frozen_string_literal: true

##
# Collection of methods to use Helper API.
##

class Helper::Client
  include HTTParty

  base_uri "https://api.helper.ai"

  HELPER_MAILBOX_SLUG = "gumroad"

  def create_hmac_digest(params: nil, json: nil)
    if (params.present? && json.present?) || (params.nil? && json.nil?)
      raise "Either params or json must be provided, but not both"
    end

    serialized_params = json ? json.to_json : params.to_query
    OpenSSL::HMAC.digest(OpenSSL::Digest.new("sha256"), GlobalConfig.get("HELPER_WIDGET_SECRET"), serialized_params)
  end

  def add_note(conversation_id:, message:)
    params = { message:, timestamp: }
    headers = get_auth_headers(json: params)
    response = self.class.post("/api/v1/mailboxes/#{HELPER_MAILBOX_SLUG}/conversations/#{conversation_id}/notes/", headers:, body: params.to_json)

    Bugsnag.notify("Helper error: could not add note", conversation_id:, message:) unless response.success?

    response.success?
  end

  def send_reply(conversation_id:, message:, draft: false, response_to: nil)
    params = { message:, response_to:, draft:, timestamp: }
    headers = get_auth_headers(json: params)
    response = self.class.post("/api/v1/mailboxes/#{HELPER_MAILBOX_SLUG}/conversations/#{conversation_id}/emails/", headers:, body: params.to_json)

    Bugsnag.notify("Helper error: could not send reply", conversation_id:, message:) unless response.success?

    response.success?
  end

  def close_conversation(conversation_id:)
    params = { status: "closed", timestamp: }
    headers = get_auth_headers(json: params)
    response = self.class.patch("/api/v1/mailboxes/#{HELPER_MAILBOX_SLUG}/conversations/#{conversation_id}/", headers:, body: params.to_json)

    Bugsnag.notify("Helper error: could not close conversation", conversation_id:) unless response.success?

    response.success?
  end

  private
    def get_auth_headers(params: nil, json: nil)
      hmac_base64 = Base64.encode64(create_hmac_digest(params:, json:))
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{hmac_base64}"
      }
    end

    def timestamp
      DateTime.current.to_i
    end
end
