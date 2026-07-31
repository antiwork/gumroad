# frozen_string_literal: true

require "spec_helper"

describe UndeliverablePingSubscriptionNotifier do
  let(:seller) { create(:user) }
  let(:oauth_app) { create(:oauth_application, owner: seller) }
  let(:resource_subscription) { create(:resource_subscription, oauth_application: oauth_app, user: seller) }

  describe "#notify" do
    it "emails the seller about a subscription whose credential was revoked" do
      expect do
        described_class.new(resource_subscription).notify
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
        .with(resource_subscription.id, described_class::REVOKED_CREDENTIAL)
    end

    it "reports a missing post URL as its own reason" do
      resource_subscription.update_column(:post_url, nil)

      expect do
        described_class.new(resource_subscription).notify
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
        .with(resource_subscription.id, described_class::MISSING_POST_URL)
    end

    it "emails once for repeated calls about the same unchanged subscription" do
      expect do
        3.times { described_class.new(resource_subscription).notify }
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription).once
    end

    it "sets the claim to expire after the notification interval" do
      described_class.new(resource_subscription).notify

      key = RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, described_class::REVOKED_CREDENTIAL)
      expect($redis.ttl(key)).to be_within(60).of(described_class::NOTIFICATION_INTERVAL.to_i)
    end

    # Redis TTLs run on wall-clock time, so travel_to cannot expire the claim. Dropping the key is
    # what the expiry does, and this asserts the seller is told again on the far side of the window.
    it "emails again once the claim has expired" do
      described_class.new(resource_subscription).notify
      $redis.del(RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, described_class::REVOKED_CREDENTIAL))

      expect do
        described_class.new(resource_subscription).notify
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription).once
    end

    it "still emails for a second reason on the same subscription" do
      described_class.new(resource_subscription).notify
      resource_subscription.update_column(:post_url, nil)

      expect do
        described_class.new(resource_subscription).notify
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
        .with(resource_subscription.id, described_class::MISSING_POST_URL)
    end

    it "deduplicates per subscription rather than across the seller's subscriptions" do
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
  end
end
