# frozen_string_literal: true

module StripeMerchantAccountHelper
  MAX_ATTEMPTS_TO_WAIT_FOR_CAPABILITIES = 12 # x 10s = 2 mins

  module_function

  def create_verified_stripe_account(params = {})
    default_params = DefaultAccountParamsBuilderService.new(country: params[:country]).perform
    stripe_account = Stripe::Account.create(default_params.deep_merge(params))

    ensure_charges_enabled(stripe_account.id)

    stripe_account
  end

  # Ensures that all requested capabilities for the account are active.
  # Each capability can have its own requirements (account fields to be provided and verified).
  def ensure_charges_enabled(stripe_account_id)
    stripe_account = Stripe::Account.retrieve(stripe_account_id)
    return if stripe_account.charges_enabled

    # We assume that all required fields have been provided.
    # Wait ~30 sec for Stripe to verify the test account (this delay seems to only happen for US-based accounts)
    attempts = 0
    while !stripe_account.charges_enabled && attempts < MAX_ATTEMPTS_TO_WAIT_FOR_CAPABILITIES
      # Sleep if we are making requests against Stripe API; otherwise fast-forward through the recorded cassette to save time
      # Debug flaky specs.
      if !VCR.turned_on? || VCR.current_cassette&.recording?
        sleep 10
        puts "*" * 100
        puts RSpec.current_example.full_description
        puts RSpec.current_example.location
        puts "VCR off: sleeping for 10 seconds"
        puts "*" * 100
      else
        puts "*" * 100
        puts RSpec.current_example.full_description
        puts RSpec.current_example.location
        puts "VCR on: fast-forwarding through the recorded cassette"
        puts VCR.current_cassette&.name
        puts "*" * 100
      end

      attempts += 1
      stripe_account = Stripe::Account.retrieve(stripe_account_id)
    end

    raise "Timed out waiting for charges to become enabled for account. Check the required fields." unless stripe_account.charges_enabled
  end

  def upload_verification_document(stripe_account_id)
    stripe_person = Stripe::Account.list_persons(stripe_account_id)["data"].last

    Stripe::Account.update_person(
      stripe_account_id,
      stripe_person.id,
      verification: {
        document: {
          front: "file_identity_document_success"
        },
      })
  end
end
