# frozen_string_literal: true

require "spec_helper"

describe UndeliverablePingSubscriptionNotifier do
  let(:seller) { create(:user) }
  let(:oauth_app) { create(:oauth_application, owner: seller) }
  let(:resource_subscription) { create(:resource_subscription, oauth_application: oauth_app, user: seller) }

  describe "#notify" do
    it "enqueues a notice for a subscription that cannot deliver" do
      expect do
        described_class.new(resource_subscription).notify
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
        .with(resource_subscription.id)
    end

    it "enqueues a notice for a subscription with no post URL" do
      resource_subscription.update_column(:post_url, nil)

      expect do
        described_class.new(resource_subscription).notify
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
        .with(resource_subscription.id)
    end

    # Whether the seller is emailed is the mailer's call; this only keeps a busy seller's sales from
    # enqueuing one render per sale.
    it "enqueues one render per subscription for a burst of sales" do
      expect do
        3.times { described_class.new(resource_subscription).notify }
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription).once
    end

    # It must expire: it is a throttle, not evidence the seller was told, and holding it forever would
    # silently stand in for the send-once claim the mailer owns.
    it "expires the enqueue throttle" do
      described_class.new(resource_subscription).notify

      key = RedisKey.undeliverable_ping_subscription_enqueued(resource_subscription.id, described_class::REVOKED_CREDENTIAL)
      expect($redis.ttl(key)).to be_between(1, described_class::ENQUEUE_THROTTLE.to_i)
    end

    # The throttle exists to stop duplicate renders, so holding a window open against an enqueue that
    # never happened would suppress the notice instead.
    it "releases the throttle when the enqueue fails" do
      allow_any_instance_of(ActionMailer::MessageDelivery).to receive(:deliver_later).and_raise(StandardError)

      expect { described_class.new(resource_subscription).notify }.to raise_error(StandardError)

      key = RedisKey.undeliverable_ping_subscription_enqueued(resource_subscription.id, described_class::REVOKED_CREDENTIAL)
      expect($redis.exists?(key)).to be false
    end

    # The reason can change while the enqueue is in flight, and the release has to free the window it
    # took: re-deriving the key frees one nobody holds and leaves the real one blocking for an hour.
    it "releases the throttle it took when the reason changes mid-enqueue" do
      taken = RedisKey.undeliverable_ping_subscription_enqueued(resource_subscription.id, described_class::REVOKED_CREDENTIAL)
      allow_any_instance_of(ActionMailer::MessageDelivery).to receive(:deliver_later) do
        resource_subscription.update_column(:post_url, nil)
        raise StandardError
      end

      expect { described_class.new(resource_subscription).notify }.to raise_error(StandardError)

      expect($redis.exists?(taken)).to be false
    end

    it "does not email about a subscription predating the subscription-cleanup cutover" do
      resource_subscription.update_column(:created_at, described_class::SUBSCRIPTION_CLEANUP_CUTOVER - 1.day)

      expect do
        described_class.new(resource_subscription).notify
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
    end

    it "emails about a subscription created on the cutover itself" do
      resource_subscription.update_column(:created_at, described_class::SUBSCRIPTION_CLEANUP_CUTOVER)

      expect do
        described_class.new(resource_subscription).notify
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
    end

    # A subscription that breaks a second way inside the throttle window is a different notice, and
    # the mailer can only send what it has been asked to render.
    it "still enqueues when the subscription breaks a second way" do
      described_class.new(resource_subscription).notify
      resource_subscription.update_column(:post_url, nil)

      expect do
        described_class.new(resource_subscription).notify
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
    end

    it "throttles per subscription rather than across the seller's subscriptions" do
      other_subscription = create(:resource_subscription, oauth_application: oauth_app, user: seller)

      expect do
        described_class.new(resource_subscription).notify
        described_class.new(other_subscription).notify
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription).twice
    end
  end

  describe ".notify_all" do
    it "notifies every subscription it is given" do
      other_subscription = create(:resource_subscription, oauth_application: oauth_app, user: seller)

      expect do
        described_class.notify_all([resource_subscription, other_subscription])
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription).twice
    end

    it "does nothing when there are no undeliverable subscriptions" do
      expect do
        described_class.notify_all([])
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
    end

    # The events that reach here are one-shot, so a skipped subscription never gets another chance.
    it "still notifies the later subscriptions when an earlier one raises" do
      other_subscription = create(:resource_subscription, oauth_application: oauth_app, user: seller)
      allow($redis).to receive(:set).and_call_original
      allow($redis).to receive(:set).with(
        RedisKey.undeliverable_ping_subscription_enqueued(resource_subscription.id, described_class::REVOKED_CREDENTIAL),
        anything,
        anything
      ).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify).once

      expect do
        described_class.notify_all([resource_subscription, other_subscription])
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
        .with(other_subscription.id)
    end

    it "keeps notifying when the error reporter also raises" do
      other_subscription = create(:resource_subscription, oauth_application: oauth_app, user: seller)
      allow($redis).to receive(:set).and_call_original
      allow($redis).to receive(:set).with(
        RedisKey.undeliverable_ping_subscription_enqueued(resource_subscription.id, described_class::REVOKED_CREDENTIAL),
        anything,
        anything
      ).and_raise(Redis::BaseError)
      allow(ErrorNotifier).to receive(:notify).and_raise(StandardError)

      expect do
        described_class.notify_all([resource_subscription, other_subscription])
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
        .with(other_subscription.id)
    end
  end

  describe ".claim_send, .record_sent and .release_claim" do
    def key_for(reason) = RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, reason)

    # The claim is what makes the send-once decision exclusive: two overlapping renders both reading an
    # absent record would both send, so the render takes the notice with one write.
    it "gives the notice to the first caller only" do
      expect(described_class.claim_send(resource_subscription.id, described_class::REVOKED_CREDENTIAL)).to be true

      expect(described_class.claim_send(resource_subscription.id, described_class::REVOKED_CREDENTIAL)).to be false
    end

    # A claim is not evidence the seller was told. It expires so a render that dies before settling
    # costs at most a delayed notice rather than a permanent one.
    it "holds the claim provisionally until the send is recorded" do
      described_class.claim_send(resource_subscription.id, described_class::REVOKED_CREDENTIAL)

      expect($redis.ttl(key_for(described_class::REVOKED_CREDENTIAL))).to be_between(1, described_class::SEND_CLAIM_TTL.to_i)
    end

    it "keeps a recorded send forever rather than letting it expire into a repeat email" do
      described_class.claim_send(resource_subscription.id, described_class::REVOKED_CREDENTIAL)
      described_class.record_sent(resource_subscription.id, described_class::REVOKED_CREDENTIAL)

      expect($redis.ttl(key_for(described_class::REVOKED_CREDENTIAL))).to eq(-1)
    end

    # Releasing is what keeps a render that sent nothing from spending the notice.
    it "lets a later render take a released claim" do
      described_class.claim_send(resource_subscription.id, described_class::REVOKED_CREDENTIAL)
      described_class.release_claim(resource_subscription.id, described_class::REVOKED_CREDENTIAL)

      expect(described_class.claim_send(resource_subscription.id, described_class::REVOKED_CREDENTIAL)).to be true
    end

    it "claims each reason separately" do
      described_class.claim_send(resource_subscription.id, described_class::REVOKED_CREDENTIAL)

      expect(described_class.claim_send(resource_subscription.id, described_class::MISSING_POST_URL)).to be true
    end

    # Silence is what this notice exists to break, so unusable bookkeeping costs a possible repeat
    # rather than the email.
    it "claims when the store cannot be written" do
      allow($redis).to receive(:set).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify)

      expect(described_class.claim_send(resource_subscription.id, described_class::REVOKED_CREDENTIAL)).to be true
    end

    it "swallows a failure to record rather than failing the delivery" do
      allow($redis).to receive(:set).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify)

      expect { described_class.record_sent(resource_subscription.id, described_class::REVOKED_CREDENTIAL) }.not_to raise_error
    end

    it "swallows a failure to release rather than failing the delivery" do
      allow($redis).to receive(:del).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify)

      expect { described_class.release_claim(resource_subscription.id, described_class::REVOKED_CREDENTIAL) }.not_to raise_error
    end

    it "ignores a blank reason on every side" do
      expect($redis).not_to receive(:set)
      expect($redis).not_to receive(:del)

      expect(described_class.claim_send(resource_subscription.id, nil)).to be false
      described_class.record_sent(resource_subscription.id, nil)
      described_class.release_claim(resource_subscription.id, nil)
    end
  end
end
