# frozen_string_literal: true

class PaypalPartnerRestCredentials
  REDIS_KEY_STORAGE_NS = Redis::Namespace.new(:paypal_partner_rest_auth_token, redis: $redis)
  TOKEN_KEY            = "token_header"

  API_RETRY_TIMEOUT_IN_SECONDS = 2 # Number of seconds before the API request is retried on failure
  API_MAX_TRIES                = 3 # Number of times the API request will be made including retries

  include HTTParty

  base_uri PAYPAL_REST_ENDPOINT
  headers("Accept" => "application/json",
          "Accept-Language" => "en_US")

  def auth_token
    load_token || generate_token
  end

  private
    def load_token
      REDIS_KEY_STORAGE_NS.get(TOKEN_KEY)
    end

    def generate_token
      store_token(request_for_api_token)
    end

    def request_for_api_token
      tries ||= API_MAX_TRIES

      self.class.post("/v1/oauth2/token",
                      body: {
                        "grant_type" => "client_credentials"
                      },
                      basic_auth: {
                        username: PAYPAL_PARTNER_CLIENT_ID,
                        password: PAYPAL_PARTNER_CLIENT_SECRET
                      })
    rescue *INTERNET_EXCEPTIONS => exception
      if (tries -= 1).zero?
        raise exception
      else
        sleep(API_RETRY_TIMEOUT_IN_SECONDS)
        retry
      end
    end

    def store_token(response)
      auth_token = "#{response['token_type']} #{response['access_token']}"

      REDIS_KEY_STORAGE_NS.set(TOKEN_KEY, auth_token)
      REDIS_KEY_STORAGE_NS.expire(TOKEN_KEY, response["expires_in"].to_i)

      auth_token
    end
end
