# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::BackfillSubscriptionCurrentEmail do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }

  before do
    allow(Sidekiq::Client).to receive(:push_bulk)
    allow(ReplicaLagWatcher).to receive(:watch)
  end

  # A membership whose member has since changed their account email: the indexed `email` still holds
  # the signup address, which is the population the search field exists for.
  def stale_membership(signup_email:, current_email:, unconfirmed_email: nil)
    buyer = create(:user, email: current_email, unconfirmed_email:)
    purchase = create(:membership_purchase, link: product, seller:, email: signup_email, purchaser: buyer)
    purchase.subscription.update!(user: buyer)
    purchase
  end

  def enqueued_ids
    calls = []
    expect(Sidekiq::Client).to have_received(:push_bulk).at_least(:once) do |args|
      calls.concat(args.fetch("args"))
    end
    calls.map { _1[1].fetch("record_id") }
  end

  it "enqueues a current-email reindex for a membership whose member changed their address" do
    purchase = stale_membership(signup_email: "signup@oldmail.example", current_email: "newname@newdomain.example")

    expect(described_class.process).to eq(scanned: 1, reindexed: 1)

    expect(Sidekiq::Client).to have_received(:push_bulk).with(
      hash_including(
        "class" => ElasticsearchIndexerWorker,
        "queue" => "low",
        "args" => [["update", { "record_id" => purchase.id, "class_name" => "Purchase", "fields" => described_class::FIELDS }]],
      )
    )
  end

  it "reindexes a membership whose member has an unconfirmed address pending" do
    purchase = stale_membership(
      signup_email: "signup@oldmail.example",
      current_email: "signup@oldmail.example",
      unconfirmed_email: "newname@newdomain.example"
    )

    expect(described_class.process).to eq(scanned: 1, reindexed: 1)
    expect(enqueued_ids).to eq([purchase.id])
  end

  # The SQL prefilter matches this row (`users.email` differs), so only the Subscription#email check
  # can reject it. A prefilter-only implementation reindexes a membership that is already findable.
  it "leaves a membership alone when the pending unconfirmed address is the one already indexed" do
    stale_membership(
      signup_email: "signup@oldmail.example",
      current_email: "someone-else@gmail.com",
      unconfirmed_email: "signup@oldmail.example"
    )

    expect(described_class.process).to eq(scanned: 1, reindexed: 0)
    expect(Sidekiq::Client).not_to have_received(:push_bulk)
  end

  it "does not scan a membership whose indexed email still matches the member's account" do
    stale_membership(signup_email: "signup@oldmail.example", current_email: "signup@oldmail.example")

    expect(described_class.process).to eq(scanned: 0, reindexed: 0)
    expect(Sidekiq::Client).not_to have_received(:push_bulk)
  end

  it "ignores recurring charges, which Customers search cannot reach" do
    purchase = stale_membership(signup_email: "signup@oldmail.example", current_email: "newname@newdomain.example")
    recurring = create(:purchase, link: product, seller:, email: "signup@oldmail.example",
                                  subscription: purchase.subscription, purchaser: purchase.purchaser)
    expect(recurring.is_original_subscription_purchase?).to be(false)

    expect(described_class.process).to eq(scanned: 1, reindexed: 1)
    expect(enqueued_ids).to eq([purchase.id])
  end

  it "reindexes only the requested seller's memberships" do
    mine = stale_membership(signup_email: "signup@oldmail.example", current_email: "newname@newdomain.example")
    other_seller = create(:user)
    other_product = create(:membership_product, user: other_seller)
    other_buyer = create(:user, email: "new@elsewhere.com")
    other = create(:membership_purchase, link: other_product, seller: other_seller,
                                         email: "old@elsewhere.com", purchaser: other_buyer)
    other.subscription.update!(user: other_buyer)

    expect(described_class.process(seller_id: seller.id)).to eq(scanned: 1, reindexed: 1)
    expect(enqueued_ids).to eq([mine.id])
  end

  it "counts without enqueueing anything when run dry" do
    stale_membership(signup_email: "signup@oldmail.example", current_email: "newname@newdomain.example")

    expect(described_class.process(dry_run: true)).to eq(scanned: 1, reindexed: 1)
    expect(Sidekiq::Client).not_to have_received(:push_bulk)
    expect(ReplicaLagWatcher).not_to have_received(:watch)
  end
end
