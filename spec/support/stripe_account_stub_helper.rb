# frozen_string_literal: true

RSpec.shared_context "with Stripe API stubs" do
  STRIPE_STUB_POSTAL_CODE_PATTERNS = {
    "AT" => /\A\d{4}\z/,
    "AU" => /\A\d{4}\z/,
    "BE" => /\A\d{4}\z/,
    "BG" => /\A\d{4}\z/,
    "BR" => /\A\d{5}-?\d{3}\z/,
    "CA" => /\A[A-Z]\d[A-Z]\s?\d[A-Z]\d\z/i,
    "CH" => /\A\d{4}\z/,
    "CY" => /\A\d{4}\z/,
    "CZ" => /\A\d{3}\s?\d{2}\z/,
    "DE" => /\A\d{5}\z/,
    "DK" => /\A\d{4}\z/,
    "EE" => /\A\d{5}\z/,
    "ES" => /\A\d{5}\z/,
    "FI" => /\A\d{5}\z/,
    "FR" => /\A\d{5}\z/,
    "GB" => /\A[A-Z]{1,2}\d[A-Z\d]?\s?\d[A-Z]{2}\z/i,
    "GR" => /\A\d{3}\s?\d{2}\z/,
    "HK" => /\A.+\z/,
    "HR" => /\A\d{5}\z/,
    "HU" => /\A\d{4}\z/,
    "IE" => /\A[A-Z\d]{3}\s?[A-Z\d]{4}\z/i,
    "IT" => /\A\d{5}\z/,
    "JP" => /\A\d{3}-?\d{4}\z/,
    "LT" => /\A(LT-)?\d{5}\z/i,
    "LU" => /\A\d{4}\z/,
    "LV" => /\A(LV-)?\d{4}\z/i,
    "MT" => /\A[A-Z]{3}\s?\d{4}\z/i,
    "NL" => /\A\d{4}\s?[A-Z]{2}\z/i,
    "NO" => /\A\d{4}\z/,
    "NZ" => /\A\d{4}\z/,
    "PL" => /\A\d{2}-?\d{3}\z/,
    "PT" => /\A\d{4}(-?\d{3})?\z/,
    "RO" => /\A\d{6}\z/,
    "SE" => /\A\d{3}\s?\d{2}\z/,
    "SG" => /\A\d{6}\z/,
    "SI" => /\A\d{4}\z/,
    "SK" => /\A\d{3}\s?\d{2}\z/,
    "US" => /\A\d{5}(-\d{4})?\z/,
  }.freeze

  before do
    stripe_accounts_metadata = {}
    stripe_accounts_country = {}

    allow(Stripe::Account).to receive(:create) do |params|
      postal_code = params.dig(:individual, :address, :postal_code) || params.dig(:company, :address, :postal_code)
      country_code = params[:country]

      if postal_code.present? && country_code.present?
        pattern = STRIPE_STUB_POSTAL_CODE_PATTERNS[country_code]
        if pattern && !postal_code.match?(pattern)
          raise Stripe::InvalidRequestError.new(
            "The postal code you entered is not valid.",
            "postal_code",
            code: "postal_code_invalid"
          )
        end
      end

      account_id = "acct_mock_#{SecureRandom.hex(8)}"
      stripe_accounts_metadata[account_id] = (params[:metadata] || {}).deep_stringify_keys
      stripe_accounts_country[account_id] = country_code || "US"

      Stripe::Account.construct_from(
        id: account_id,
        object: "account",
        country: country_code || "US",
        default_currency: params[:default_currency] || "usd",
        charges_enabled: true,
        capabilities: { "card_payments" => "active", "transfers" => "active" },
        external_accounts: {
          object: "list",
          data: [
            {
              id: "ba_mock_#{SecureRandom.hex(8)}",
              object: "bank_account",
              fingerprint: "fp_mock_#{SecureRandom.hex(8)}"
            }
          ]
        },
        metadata: params[:metadata] || {},
        requirements: { "currently_due" => [], "past_due" => [] }
      )
    end

    allow(Stripe::Account).to receive(:retrieve) do |account_id, *_args|
      metadata = stripe_accounts_metadata[account_id] || {}
      country = stripe_accounts_country[account_id] || "US"

      Stripe::Account.construct_from(
        id: account_id,
        object: "account",
        country: country,
        default_currency: country == "US" ? "usd" : "eur",
        charges_enabled: true,
        capabilities: { "card_payments" => "active", "transfers" => "active" },
        external_accounts: {
          object: "list",
          data: [
            {
              id: "ba_mock_#{SecureRandom.hex(8)}",
              object: "bank_account",
              fingerprint: "fp_mock_#{SecureRandom.hex(8)}"
            }
          ]
        },
        metadata: metadata,
        requirements: { "currently_due" => [], "past_due" => [] }
      )
    end

    allow(Stripe::Account).to receive(:update) do |account_id, params|
      if params.is_a?(Hash) && params[:metadata].present? && stripe_accounts_metadata[account_id]
        stripe_accounts_metadata[account_id].merge!(params[:metadata].deep_stringify_keys)
      end

      metadata = stripe_accounts_metadata[account_id] || {}
      country = stripe_accounts_country[account_id] || "US"

      Stripe::Account.construct_from(
        id: account_id,
        object: "account",
        country: country,
        default_currency: country == "US" ? "usd" : "eur",
        charges_enabled: true,
        capabilities: { "card_payments" => "active", "transfers" => "active" },
        external_accounts: {
          object: "list",
          data: [
            {
              id: "ba_mock_#{SecureRandom.hex(8)}",
              object: "bank_account",
              fingerprint: "fp_mock_#{SecureRandom.hex(8)}"
            }
          ]
        },
        metadata: metadata,
        requirements: { "currently_due" => [], "past_due" => [] }
      )
    end

    allow(Stripe::Account).to receive(:delete) do |account_id, *_args|
      Stripe::StripeObject.construct_from(deleted: true, id: account_id)
    end

    allow(Stripe::Account).to receive(:create_person) do |_account_id, _params|
      Stripe::StripeObject.construct_from(
        id: "person_mock_#{SecureRandom.hex(8)}",
        object: "person"
      )
    end

    allow(Stripe::Account).to receive(:list_persons) do |_account_id, *_args|
      {
        "data" => [
          Stripe::StripeObject.construct_from(
            id: "person_mock_#{SecureRandom.hex(8)}",
            object: "person"
          )
        ]
      }
    end

    allow(Stripe::Account).to receive(:update_person) do |_account_id, person_id, _params|
      Stripe::StripeObject.construct_from(
        id: person_id,
        object: "person"
      )
    end

    allow(Stripe::Token).to receive(:create) do |_params, *_opts|
      Stripe::StripeObject.construct_from(
        id: "tok_mock_#{SecureRandom.hex(8)}",
        object: "token"
      )
    end

    allow(Stripe::AccountLink).to receive(:create) do |params|
      Stripe::StripeObject.construct_from(
        url: params[:return_url] || "https://example.com/mock-onboarding",
        object: "account_link"
      )
    end
  end
end
