# frozen_string_literal: true

require "rails_helper"

describe RichContentPageView do
  describe "validations" do
    it "requires rich_content_id" do
      view = build(:rich_content_page_view, rich_content_id: nil)
      expect(view).not_to be_valid
      expect(view.errors[:rich_content_id]).to be_present
    end

    it "requires purchase_id" do
      view = build(:rich_content_page_view, purchase_id: nil)
      expect(view).not_to be_valid
      expect(view.errors[:purchase_id]).to be_present
    end

    it "requires product_id" do
      view = build(:rich_content_page_view, product_id: nil)
      expect(view).not_to be_valid
      expect(view.errors[:product_id]).to be_present
    end

    it "requires viewed_at" do
      view = build(:rich_content_page_view, viewed_at: nil)
      expect(view).not_to be_valid
      expect(view.errors[:viewed_at]).to be_present
    end

    it "allows buyer_id to be nil" do
      view = build(:rich_content_page_view, buyer_id: nil)
      expect(view).to be_valid
    end
  end

  describe "associations" do
    it "belongs to rich_content" do
      association = described_class.reflect_on_association(:rich_content)
      expect(association.macro).to eq(:belongs_to)
    end

    it "belongs to purchase" do
      association = described_class.reflect_on_association(:purchase)
      expect(association.macro).to eq(:belongs_to)
    end

    it "belongs to product" do
      association = described_class.reflect_on_association(:product)
      expect(association.macro).to eq(:belongs_to)
      expect(association.options[:class_name]).to eq("Link")
    end

    it "belongs to buyer" do
      association = described_class.reflect_on_association(:buyer)
      expect(association.macro).to eq(:belongs_to)
      expect(association.options[:class_name]).to eq("User")
      expect(association.options[:optional]).to be true
    end
  end

  describe "scopes" do
    let(:product) { create(:product) }
    let(:rich_content) { create(:rich_content, entity: product) }
    let(:purchase) { create(:purchase, link: product) }

    before do
      create(:rich_content_page_view, product:, rich_content:, purchase:, viewed_at: 5.days.ago)
      create(:rich_content_page_view, product:, rich_content:, purchase:, viewed_at: 2.days.ago)
    end

    describe ".for_product" do
      it "returns views for a specific product" do
        other_product = create(:product)
        other_view = create(:rich_content_page_view, product: other_product)

        views = RichContentPageView.for_product(product.id)
        expect(views.count).to eq(2)
        expect(views).not_to include(other_view)
      end
    end

    describe ".for_rich_content" do
      it "returns views for a specific rich content" do
        other_content = create(:rich_content, entity: product)
        other_view = create(:rich_content_page_view, rich_content: other_content, product:, purchase:)

        views = RichContentPageView.for_rich_content(rich_content.id)
        expect(views.count).to eq(2)
        expect(views).not_to include(other_view)
      end
    end

    describe ".in_date_range" do
      it "returns views within date range" do
        start_date = 3.days.ago.to_date
        end_date = 1.day.ago.to_date

        views = RichContentPageView.in_date_range(start_date, end_date)
        expect(views.count).to eq(1)
        expect(views.first.viewed_at).to be_between(start_date.beginning_of_day, end_date.end_of_day)
      end
    end
  end

  describe ".record_view!" do
    let(:product) { create(:product) }
    let(:rich_content) { create(:rich_content, entity: product) }
    let(:purchase) { create(:purchase, link: product) }
    let(:buyer) { purchase.user }

    it "creates a new page view record" do
      expect {
        RichContentPageView.record_view!(
          rich_content_id: rich_content.id,
          purchase_id: purchase.id,
          product_id: product.id,
          buyer_id: buyer.id,
          url_redirect_id: "test_redirect",
          ip_address: "192.168.1.1",
          user_agent: "TestAgent",
          viewed_at: Time.current
        )
      }.to change(RichContentPageView, :count).by(1)
    end

    it "stores all provided attributes" do
      view = RichContentPageView.record_view!(
        rich_content_id: rich_content.id,
        purchase_id: purchase.id,
        product_id: product.id,
        buyer_id: buyer.id,
        url_redirect_id: "test_redirect",
        ip_address: "192.168.1.1",
        user_agent: "TestAgent"
      )

      expect(view.rich_content_id).to eq(rich_content.id)
      expect(view.purchase_id).to eq(purchase.id)
      expect(view.product_id).to eq(product.id)
      expect(view.buyer_id).to eq(buyer.id)
      expect(view.url_redirect_id).to eq("test_redirect")
      expect(view.ip_address).to eq("192.168.1.1")
      expect(view.user_agent).to eq("TestAgent")
    end

    it "defaults viewed_at to current time" do
      freeze_time do
        view = RichContentPageView.record_view!(
          rich_content_id: rich_content.id,
          purchase_id: purchase.id,
          product_id: product.id
        )
        expect(view.viewed_at).to be_within(1.second).of(Time.current)
      end
    end
  end
end
