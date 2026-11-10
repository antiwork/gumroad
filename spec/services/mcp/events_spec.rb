# frozen_string_literal: true

require "spec_helper"

describe Mcp::Events do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, name: "Field notes") }
  let(:purchase) { create(:free_purchase, link: product, seller:) }

  describe ".sale_created" do
    it "identifies the sale with exactly the fields the payload schema names", :freeze_time do
      event = described_class.sale_created(purchase)

      expect(event).to eq(
        "eventId" => "evt_sale_#{ObfuscateIds.encrypt(purchase.id, padding: false)}",
        "name" => "sale.created",
        "timestamp" => purchase.created_at.utc.iso8601,
        "data" => {
          "sale_id" => purchase.external_id,
          "product_id" => product.external_id,
          "product_name" => "Field notes",
          "price_cents" => 0,
          "currency" => "usd",
          "created_at" => purchase.created_at.utc.iso8601
        },
        "cursor" => nil
      )
      expect(event["data"].keys).to eq(described_class::DESCRIPTORS.sole[:payloadSchema][:required])
    end

    it "gives the same event id for the same sale, in characters a webhook-id header allows" do
      ids = 2.times.map { described_class.sale_created(purchase.reload)["eventId"] }

      expect(ids.uniq.size).to eq(1)
      expect(ids.first).to match(/\A[A-Za-z0-9_-]+\z/)
    end
  end

  describe ".publish_sale" do
    before { Feature.activate_user(:mcp_events, seller) }

    let!(:subscription) { create(:mcp_event_subscription, user: seller) }

    it "queues one delivery for each live sale subscription of the seller" do
      second = create(:mcp_event_subscription, user: seller, callback_url: "https://example.org/hooks/mcp")
      create(:mcp_event_subscription, user: seller, callback_url: "https://example.net/hooks/mcp", expires_at: 1.minute.ago)
      create(:mcp_event_subscription)

      described_class.publish_sale(purchase)

      expect(Mcp::DeliverEventJob.jobs.map { _1["args"] }).to contain_exactly(
        [subscription.id, described_class.sale_created(purchase)],
        [second.id, described_class.sale_created(purchase)]
      )
    end

    it "queues nothing for a seller without the flag" do
      Feature.deactivate_user(:mcp_events, seller)

      described_class.publish_sale(purchase)

      expect(Mcp::DeliverEventJob.jobs.size).to eq(0)
    end

    it "reads nothing more, the flag included, for a seller with no subscription" do
      sale = purchase
      subscription.delete
      expect(Feature).not_to receive(:active?).with(:mcp_events, anything)

      described_class.publish_sale(sale)

      expect(Mcp::DeliverEventJob.jobs.size).to eq(0)
    end

    it "queues nothing for a purchase that list_sales does not show" do
      %w[failed test_successful not_charged].each do |purchase_state|
        described_class.publish_sale(create(:free_purchase, link: product, seller:, purchase_state:))
      end

      expect(Mcp::DeliverEventJob.jobs.size).to eq(0)
    end

    it "queues nothing for a purchase that belongs to an order that already fired" do
      described_class.publish_sale(create(:free_purchase, link: product, seller:, is_bundle_product_purchase: true))
      # The charge a preorder makes at release. Its validations need a whole preorder, which this check does not read.
      release_charge = create(:free_purchase, link: product, seller:).tap { _1.update_columns(preorder_id: create(:preorder).id) }
      described_class.publish_sale(release_charge)

      expect(Mcp::DeliverEventJob.jobs.size).to eq(0)
    end

    it "reports a preorder when the buyer places it" do
      authorization = create(:preorder_authorization_purchase, link: product, seller:, is_preorder_authorization: true)

      described_class.publish_sale(authorization)

      expect(Mcp::DeliverEventJob.jobs.sole["args"].last.dig("data", "sale_id")).to eq(authorization.external_id)
    end

    it "queues nothing for a sale whose ping is sent again a day or more later" do
      described_class.publish_sale(create(:free_purchase, link: product, seller:, succeeded_at: 2.days.ago))

      expect(Mcp::DeliverEventJob.jobs.size).to eq(0)
    end

    it "queues nothing for a gift whose gift row is gone" do
      described_class.publish_sale(create(:free_purchase, :gift_receiver, link: product, seller:))

      expect(Mcp::DeliverEventJob.jobs.size).to eq(0)
    end

    it "reports a gift once, as the gifter's purchase" do
      gifter_purchase = create(:free_purchase, :gift_sender, link: product, seller:)
      giftee_purchase = create(:free_purchase, :gift_receiver, link: product, seller:)
      create(:gift, link: product, gifter_purchase:, giftee_purchase:)

      # Reloaded, as the ping worker loads it: validation cached the gift association before the gift existed.
      described_class.publish_sale(giftee_purchase.reload)

      expect(Mcp::DeliverEventJob.jobs.sole["args"].last.dig("data", "sale_id")).to eq(gifter_purchase.external_id)
    end
  end
end
