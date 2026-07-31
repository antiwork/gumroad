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

  describe ".record_sent and .already_sent?" do
    def key_for(reason) = RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, reason)

    # The record is written after delivery, not before: writing it earlier means a send that raises
    # or is declined spends a notice that has no expiry to give it back.
    it "reports a reason as sent only once it has been recorded" do
      expect(described_class.already_sent?(resource_subscription.id, described_class::REVOKED_CREDENTIAL)).to be false

      described_class.record_sent(resource_subscription.id, described_class::REVOKED_CREDENTIAL)

      expect(described_class.already_sent?(resource_subscription.id, described_class::REVOKED_CREDENTIAL)).to be true
    end

    it "keeps the record forever rather than letting it expire into a repeat email" do
      described_class.record_sent(resource_subscription.id, described_class::REVOKED_CREDENTIAL)

      expect($redis.ttl(key_for(described_class::REVOKED_CREDENTIAL))).to eq(-1)
    end

    it "records each reason separately" do
      described_class.record_sent(resource_subscription.id, described_class::REVOKED_CREDENTIAL)

      expect(described_class.already_sent?(resource_subscription.id, described_class::MISSING_POST_URL)).to be false
    end

    # Silence is what this notice exists to break, so unreadable bookkeeping costs a possible repeat
    # rather than the email.
    it "treats an unreadable record as not sent" do
      allow($redis).to receive(:exists?).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify)

      expect(described_class.already_sent?(resource_subscription.id, described_class::REVOKED_CREDENTIAL)).to be false
    end

    it "swallows a failure to record rather than failing the delivery" do
      allow($redis).to receive(:set).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify)

      expect { described_class.record_sent(resource_subscription.id, described_class::REVOKED_CREDENTIAL) }.not_to raise_error
    end

    it "ignores a blank reason on both sides" do
      expect($redis).not_to receive(:set)

      described_class.record_sent(resource_subscription.id, nil)
      expect(described_class.already_sent?(resource_subscription.id, nil)).to be false
    end
  end
end
