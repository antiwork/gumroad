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

    # The seller cannot act on a repeat, so the claim has to outlive any window.
    it "keeps the claim forever rather than letting it expire into a repeat email" do
      described_class.new(resource_subscription).notify

      key = RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, described_class::REVOKED_CREDENTIAL)
      expect($redis.ttl(key)).to eq(-1)
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

    # The events that reach here are one-shot, so a skipped subscription never gets another chance.
    it "still notifies the later subscriptions when an earlier one raises" do
      other_subscription = create(:resource_subscription, oauth_application: oauth_app, user: seller)
      allow($redis).to receive(:set).and_call_original
      allow($redis).to receive(:set).with(
        RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, described_class::REVOKED_CREDENTIAL),
        anything,
        anything
      ).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify).once

      expect do
        described_class.notify_all([resource_subscription, other_subscription])
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
        .with(other_subscription.id, described_class::REVOKED_CREDENTIAL)
    end

    it "keeps notifying when the error reporter also raises" do
      other_subscription = create(:resource_subscription, oauth_application: oauth_app, user: seller)
      allow($redis).to receive(:set).and_call_original
      allow($redis).to receive(:set).with(
        RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, described_class::REVOKED_CREDENTIAL),
        anything,
        anything
      ).and_raise(Redis::BaseError)
      allow(ErrorNotifier).to receive(:notify).and_raise(StandardError)

      expect do
        described_class.notify_all([resource_subscription, other_subscription])
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
        .with(other_subscription.id, described_class::REVOKED_CREDENTIAL)
    end
  end

  describe ".release_claim" do
    it "lets the same reason be notified again" do
      described_class.new(resource_subscription).notify
      described_class.release_claim(resource_subscription.id, described_class::REVOKED_CREDENTIAL)

      expect do
        described_class.new(resource_subscription).notify
      end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
        .with(resource_subscription.id, described_class::REVOKED_CREDENTIAL)
    end

    it "leaves other reasons claimed" do
      described_class.new(resource_subscription).notify
      described_class.release_claim(resource_subscription.id, described_class::MISSING_POST_URL)

      key = RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, described_class::REVOKED_CREDENTIAL)
      expect($redis.exists?(key)).to be true
    end

    # Jobs enqueued before the reason argument existed pass nil, and deleting that key would be
    # deleting a claim nothing took.
    it "does nothing without a reason" do
      expect($redis).not_to receive(:del)

      described_class.release_claim(resource_subscription.id, nil)
    end

    it "swallows a Redis failure rather than failing the render" do
      allow($redis).to receive(:del).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify)

      expect { described_class.release_claim(resource_subscription.id, described_class::REVOKED_CREDENTIAL) }.not_to raise_error
    end
  end

  describe ".reconcile_claim" do
    def key_for(reason) = RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, reason)

    it "leaves the claim alone when the advice still matches it" do
      described_class.new(resource_subscription).notify

      expect(
        described_class.reconcile_claim(
          resource_subscription.id,
          claimed: described_class::REVOKED_CREDENTIAL,
          rendered: described_class::REVOKED_CREDENTIAL
        )
      ).to be true
      expect($redis.exists?(key_for(described_class::REVOKED_CREDENTIAL))).to be true
    end

    # The claim has to name the advice the seller was actually given, or the notice they are owed for
    # the other reason is refused by a claim taken under a reason nobody told them about.
    it "moves the claim to the advice being sent" do
      described_class.new(resource_subscription).notify

      expect(
        described_class.reconcile_claim(
          resource_subscription.id,
          claimed: described_class::REVOKED_CREDENTIAL,
          rendered: described_class::MISSING_POST_URL
        )
      ).to be true
      expect($redis.exists?(key_for(described_class::MISSING_POST_URL))).to be true
      expect($redis.exists?(key_for(described_class::REVOKED_CREDENTIAL))).to be false
    end

    it "refuses a send whose advice was already sent once under its own reason" do
      $redis.set(key_for(described_class::MISSING_POST_URL), Time.current.to_i)

      expect(
        described_class.reconcile_claim(
          resource_subscription.id,
          claimed: described_class::REVOKED_CREDENTIAL,
          rendered: described_class::MISSING_POST_URL
        )
      ).to be false
    end

    # The claim is wrong either way at that point, and this notice exists to break silence.
    it "sends rather than withholds when the bookkeeping itself fails" do
      allow($redis).to receive(:set).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify)

      expect(
        described_class.reconcile_claim(
          resource_subscription.id,
          claimed: described_class::REVOKED_CREDENTIAL,
          rendered: described_class::MISSING_POST_URL
        )
      ).to be true
    end
  end
end
