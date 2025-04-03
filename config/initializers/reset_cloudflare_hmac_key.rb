# frozen_string_literal: true

Rails.application.credentials.cloudflare_hmac_key = "sample_key" if Rails.env.test?
