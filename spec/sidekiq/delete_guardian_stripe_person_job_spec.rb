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
      .and_raise(Stripe::InvalidRequestError.new("No such person: 'person_retry_me'", nil, code: "resource_missing"))

    expect { described_class.new.perform("person_retry_me", "acct_retry", user.id) }
      .not_to raise_error
  end

  it "stops retrying when the Stripe account itself is gone" do
    allow(Stripe::Account).to receive(:delete_person)
      .and_raise(Stripe::InvalidRequestError.new("No such account: 'acct_retry'", nil, code: "resource_missing"))

    expect { described_class.new.perform("person_retry_me", "acct_retry", user.id) }
      .not_to raise_error
  end

  # A refusal to delete is not a missing resource. Swallowing it would report an erasure that left
  # the guardian's details at Stripe, so it has to reach Sidekiq and be retried.
  it "re-raises a Stripe refusal that is not a missing resource" do
    allow(Stripe::Account).to receive(:delete_person)
      .and_raise(Stripe::InvalidRequestError.new("Cannot delete the account representative", nil))

    expect { described_class.new.perform("person_retry_me", "acct_retry", user.id) }
      .to raise_error(Stripe::InvalidRequestError)
  end

  # The last line of defense against retained third-party PII cannot end in the dead set silently.
  describe "when the retries are exhausted" do
    let(:message) do
      { "args" => ["person_retry_me", "acct_retry", user.id] }
    end

    it "notifies and records a breadcrumb naming the person still held at Stripe" do
      expect(ErrorNotifier).to receive(:notify).with(/person_retry_me.*acct_retry/m)

      described_class.sidekiq_retries_exhausted_block.call(message, StandardError.new("boom"))

      note = user.reload.comments.last
      expect(note.comment_type).to eq(Comment::COMMENT_TYPE_PAYOUT_NOTE)
      expect(note.content).to include("person_retry_me")
      expect(note.content).to include("still held at Stripe")
    end
  end
end
