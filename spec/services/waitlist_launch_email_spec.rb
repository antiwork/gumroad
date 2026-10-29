# frozen_string_literal: true

require "spec_helper"

describe WaitlistLaunchEmail do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Snooze Bar") }
  let(:service) { described_class.new(product:) }

  def join(confirmed: true)
    follower = confirmed ? create(:active_follower, user: seller) : create(:follower, user: seller)
    create(:waitlist_entry, follower:, product:)
  end

  def eligible!
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:payment_completed, user: seller)
  end

  describe "#props" do
    it "is nil until someone confirms a signup" do
      join(confirmed: false)

      expect(service.props).to be_nil
    end

    it "counts confirmed signups and explains why a new seller cannot email them" do
      2.times { join }
      join(confirmed: false)

      expect(service.props).to eq(
        count: 2,
        blocked_reason: "You can email your waitlist once you've made at least $100 in sales and received a payout.",
        email: nil,
      )
    end

    it "reports the email once it exists, and its state" do
      eligible!
      join
      email = service.find_or_create_email!

      props = described_class.new(product:).props
      expect(props[:blocked_reason]).to be_nil
      expect(props[:email]).to eq(state: "draft", edit_url: "/emails/#{email.external_id}/edit")

      email.update!(published_at: 1.hour.ago)
      expect(described_class.new(product:).props[:email][:state]).to eq("published")

      create(:blast, post: email, requested_at: 1.hour.ago, completed_at: 1.minute.ago)
      expect(described_class.new(product:).props[:email][:state]).to eq("sent")
    end
  end

  describe "#find_or_create_email!" do
    before { eligible! }

    it "starts a follower email addressed to this product's waitlist" do
      join
      email = service.find_or_create_email!

      expect(email).to be_follower_type
      expect(email.waitlisted_products).to eq([product.unique_permalink])
      expect(email.name).to eq("Snooze Bar is out now")
      expect(email.message).to include("You asked to hear when Snooze Bar launches. It's out now.", product.long_url)
      expect(email.published_at).to be_nil
      expect(email.audience_members_filter_params).to include(type: "follower", waitlisted_product_ids: [product.id])
    end

    it "reuses the email on a second click and starts a new one after the seller deletes it" do
      first = service.find_or_create_email!
      expect(described_class.new(product:).find_or_create_email!).to eq(first)

      first.mark_deleted!
      expect(described_class.new(product:).find_or_create_email!).not_to eq(first)
    end

    it "keeps one email per product" do
      other = create(:product, user: seller)

      expect(described_class.new(product: other).find_or_create_email!).not_to eq(service.find_or_create_email!)
    end
  end
end
