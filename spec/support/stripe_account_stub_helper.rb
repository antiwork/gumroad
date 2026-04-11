# frozen_string_literal: true

RSpec.shared_context "with Stripe API stubs" do
  before do
    stripe_accounts_metadata = {}

    allow(Stripe::Account).to receive(:create) do |params|
      account_id = "acct_mock_#{SecureRandom.hex(8)}"
      stripe_accounts_metadata[account_id] = (params[:metadata] || {}).deep_stringify_keys

      Stripe::Account.construct_from(
        id: account_id,
        object: "account",
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

      Stripe::Account.construct_from(
        id: account_id,
        object: "account",
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

      Stripe::Account.construct_from(
        id: account_id,
        object: "account",
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
