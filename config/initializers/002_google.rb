# frozen_string_literal: true

GOOGLE_CLIENT_ID = GlobalConfig.get("GOOGLE_CLIENT_ID", Rails.env.test? ? "test-google-client-id" : nil)
GOOGLE_CLIENT_SECRET = GlobalConfig.get("GOOGLE_CLIENT_SECRET", Rails.env.test? ? "test-google-client-secret" : nil)
