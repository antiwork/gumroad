# frozen_string_literal: true

require "spec_helper"

describe DeleteGuardianStripePersonJob do
  let(:user) { create(:user) }

  it "deletes the guardian person from Stripe" do
    allow(Stripe::Account).to receive(:delete_person)

    described_class.new.perform("person_retry_me", "acct_retry", user.id)

    expect(Stripe::Account).to have_received(:delete_person).with("acct_retry", "person_retry_me")
  end

  # The whole point of the retry: an error must reach Sidekiq so it runs again. Swallowing it here
  # would burn the only remaining attempt at reaching the adult's data still held at Stripe.
  it "re-raises so Sidekiq retries" do
    allow(Stripe::Account).to receive(:delete_person)
      .and_raise(Stripe::APIError.new("Stripe is down"))

    expect { described_class.new.perform("person_retry_me", "acct_retry", user.id) }
      .to raise_error(Stripe::APIError)
  end

  # Idempotency is what makes retrying safe: a Person the previous attempt already removed must
  # not turn into a permanently failing job.
  it "treats an already-deleted person as done" do
    allow(Stripe::Account).to receive(:delete_person)
      .and_raise(Stripe::InvalidRequestError.new("No such person: 'person_retry_me'", nil))

    expect { described_class.new.perform("person_retry_me", "acct_retry", user.id) }
      .not_to raise_error
  end

  it "stops retrying when the Stripe account itself is gone" do
    allow(Stripe::Account).to receive(:delete_person)
      .and_raise(Stripe::InvalidRequestError.new("No such account: 'acct_retry'", nil))

    expect { described_class.new.perform("person_retry_me", "acct_retry", user.id) }
      .not_to raise_error
  end
end
