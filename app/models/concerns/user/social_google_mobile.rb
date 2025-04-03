# frozen_string_literal: true

module User::SocialGoogleMobile
  extend ActiveSupport::Concern

  class_methods do
    def find_for_google_mobile_auth(google_id_token:)
      email = email_from_google_id_token(google_id_token:)
      return if email.blank?

      User.find_by(email:)
    end

    private
      def email_from_google_id_token(google_id_token:)
        key_source = Google::Auth::IDTokens::JwkHttpKeySource.new(Google::Auth::IDTokens::OAUTH2_V3_CERTS_URL)
        verifier = Google::Auth::IDTokens::Verifier.new(key_source:)
        client_id = GlobalConfig.get("GOOGLE_CLIENT_ID")

        begin
          payload = verifier.verify(google_id_token)
          audience = payload["aud"]
          email_verified = payload["email_verified"]

          payload["email"] if audience == client_id && email_verified
        rescue
          nil
        end
      end
  end
end
