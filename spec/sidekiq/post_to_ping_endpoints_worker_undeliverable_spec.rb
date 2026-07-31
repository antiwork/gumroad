# frozen_string_literal: true

require "spec_helper"

# The surrounding post_to_ping_endpoints_worker_spec.rb cannot run locally (its purchase factory
# needs live Stripe), so the undeliverable-notification wiring is covered here with a stubbed
# payload instead of a real charge.
describe PostToPingEndpointsWorker, "undeliverable subscription notifications" do
  let(:seller) { create(:user) }
  let(:oauth_application) { create(:oauth_application, owner: seller) }
  let(:product) { create(:product, user: seller) }
  # free_purchase skips the card charge, so this runs without live Stripe.
  let(:purchase) { create(:free_purchase, link: product, seller:) }

  before do
    allow(Purchase).to receive(:find).with(purchase.id).and_return(purchase)
    allow(purchase).to receive(:payload_for_ping_notification).and_return({ sale_id: "x" })
  end

  it "notifies the seller when an alive subscription cannot deliver" do
    token = create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "view_sales")
    subscription = create(:resource_subscription, oauth_application:, user: seller)
    token.update!(revoked_at: Time.current)

    expect(UndeliverablePingSubscriptionNotifier).to receive(:notify_all).with([subscription]).and_call_original

    described_class.new.perform(purchase.id, nil)
  end

  it "still enqueues delivery for the deliverable subscriptions alongside the notification" do
    create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "view_sales")
    deliverable = create(:resource_subscription, oauth_application:, user: seller)

    other_application = create(:oauth_application, owner: seller)
    broken_token = create("doorkeeper/access_token", application: other_application, resource_owner_id: seller.id, scopes: "view_sales")
    broken = create(:resource_subscription, oauth_application: other_application, user: seller)
    broken_token.update!(revoked_at: Time.current)

    expect(UndeliverablePingSubscriptionNotifier).to receive(:notify_all).with([broken]).and_call_original

    expect do
      described_class.new.perform(purchase.id, nil)
    end.to change { PostToIndividualPingEndpointWorker.jobs.size }.by(1)

    expect(PostToIndividualPingEndpointWorker.jobs.last["args"].first).to eq(deliverable.post_url)
  end

  # The early return on an empty URL list is exactly the silence this notification exists to break,
  # so it has to fire before that return rather than after it.
  it "notifies even though there is nothing to deliver and the worker returns early" do
    token = create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "view_sales")
    create(:resource_subscription, oauth_application:, user: seller)
    token.update!(revoked_at: Time.current)

    expect do
      described_class.new.perform(purchase.id, nil)
    end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)

    expect(PostToIndividualPingEndpointWorker.jobs).to be_empty
  end

  it "does not notify when every alive subscription is deliverable" do
    create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "view_sales")
    create(:resource_subscription, oauth_application:, user: seller)

    expect do
      described_class.new.perform(purchase.id, nil)
    end.not_to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription)
  end

  it "does not notify the seller repeatedly across consecutive sales" do
    token = create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "view_sales")
    create(:resource_subscription, oauth_application:, user: seller)
    token.update!(revoked_at: Time.current)

    expect do
      3.times { described_class.new.perform(purchase.id, nil) }
    end.to have_enqueued_mail(ContactingCreatorMailer, :undeliverable_ping_subscription).once
  end

  # This queue is :critical. The notification is a side-feature and must never gate the webhooks
  # that do work.
  it "still delivers the working webhooks when notifying raises" do
    create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "view_sales")
    deliverable = create(:resource_subscription, oauth_application:, user: seller)

    other_application = create(:oauth_application, owner: seller)
    broken_token = create("doorkeeper/access_token", application: other_application, resource_owner_id: seller.id, scopes: "view_sales")
    create(:resource_subscription, oauth_application: other_application, user: seller)
    broken_token.update!(revoked_at: Time.current)

    allow(UndeliverablePingSubscriptionNotifier).to receive(:notify_all).and_raise(Redis::CannotConnectError)
    expect(ErrorNotifier).to receive(:notify).with(instance_of(Redis::CannotConnectError))

    expect do
      described_class.new.perform(purchase.id, nil)
    end.to change { PostToIndividualPingEndpointWorker.jobs.size }.by(1)

    expect(PostToIndividualPingEndpointWorker.jobs.last["args"].first).to eq(deliverable.post_url)
  end

  # Same reason, one layer down: an outage that takes Redis with it can take the Sentry transport
  # too, and a raising reporter must not become the thing that drops the webhooks.
  it "still delivers the working webhooks when the error reporter also raises" do
    create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "view_sales")
    deliverable = create(:resource_subscription, oauth_application:, user: seller)

    other_application = create(:oauth_application, owner: seller)
    broken_token = create("doorkeeper/access_token", application: other_application, resource_owner_id: seller.id, scopes: "view_sales")
    create(:resource_subscription, oauth_application: other_application, user: seller)
    broken_token.update!(revoked_at: Time.current)

    allow(UndeliverablePingSubscriptionNotifier).to receive(:notify_all).and_raise(Redis::CannotConnectError)
    allow(ErrorNotifier).to receive(:notify).and_raise(StandardError, "sentry down")

    expect do
      described_class.new.perform(purchase.id, nil)
    end.to change { PostToIndividualPingEndpointWorker.jobs.size }.by(1)

    expect(PostToIndividualPingEndpointWorker.jobs.last["args"].first).to eq(deliverable.post_url)
  end
end
