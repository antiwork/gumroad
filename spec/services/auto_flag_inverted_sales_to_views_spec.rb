# frozen_string_literal: true

require "spec_helper"

describe AutoFlagInvertedSalesToViews, :elasticsearch_wait_for_refresh do
  include ProductPageViewHelpers

  before { recreate_model_index(ProductPageView) }

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 0) }

  def create_free_sales(count, on: product, at: 10.minutes.ago)
    count.times { create(:free_purchase, link: on, seller: on.user, created_at: at, succeeded_at: at) }
  end

  def add_views(count, on: product, at: 10.minutes.ago)
    count.times { add_page_view(on, at.iso8601) }
  end

  describe "#process" do
    # The real floor is 500 sales in an hour, which would make every example here create
    # 500 purchase rows. The shipped value is asserted separately below against the
    # constant, so the behavioural examples run against a smaller stand-in.
    before { stub_const("#{described_class}::MIN_FREE_SALES_IN_WINDOW", 3) }

    context "when a product's free sales far exceed its page views" do
      before { create_free_sales(20) }

      it "unpublishes the product so no further checkouts can go through" do
        expect do
          described_class.new.process
        end.to change { product.reload.alive? }.from(true).to(false)

        expect(product.reload.is_unpublished_by_admin).to be(true)
      end

      it "flags the seller for a policy violation with the numbers on the comment" do
        described_class.new.process

        seller.reload
        expect(seller.flagged_for_tos_violation?).to be(true)
        expect(seller.tos_violation_reason).to eq(described_class::TOS_VIOLATION_REASON)
        comment = seller.comments.with_type_flagged.last
        expect(comment.author_name).to eq(described_class::FLAG_AUTHOR_NAME)
        expect(comment.content).to include("20 free sales against 0 product page views")
      end

      it "emails risk with the counts, since the release decision is a human's" do
        expect do
          described_class.new.process
        end.to have_enqueued_mail(AdminMailer, :inverted_sales_to_views_notify).with(product.id, 20, 0)
      end

      it "returns the ids of the products it acted on" do
        expect(described_class.new.process).to eq([product.id])
      end
    end

    context "when views keep pace with sales" do
      before do
        create_free_sales(20)
        add_views(20)
      end

      it "leaves the product alone" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }

        expect(seller.reload.flagged_for_tos_violation?).to be(false)
      end
    end

    context "when sales exceed views but not by the inversion multiplier" do
      before do
        create_free_sales(20)
        # 20 sales against 8 views is 2.5x, under the 5x bar — the kind of gap a product
        # sold through an embed or a direct link legitimately produces.
        add_views(8)
      end

      it "leaves the product alone" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "when the product is under the minimum sales volume" do
      before { create_free_sales(2) }

      it "leaves the product alone, because a handful of sales with no indexed views proves nothing" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "when the sales are paid rather than free" do
      let(:paid_product) { create(:product, user: seller, price_cents: 10_00) }

      before do
        # Built as free purchases and then repriced, so the factory doesn't try to charge a
        # card 20 times. Only price_cents matters here — it's what the detector filters on.
        20.times do
          purchase = create(:free_purchase, link: paid_product, seller:, created_at: 10.minutes.ago)
          purchase.update_columns(price_cents: 10_00, displayed_price_cents: 10_00)
        end
      end

      it "leaves the product alone, because paid sales don't turn the receipt mailer into a bulk mailer" do
        expect do
          described_class.new.process
        end.not_to change { paid_product.reload.alive? }
      end
    end

    context "when the sales happened before the window" do
      before { create_free_sales(20, at: 5.hours.ago) }

      it "leaves the product alone" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "when the seller is a team member" do
      let(:seller) { create(:user, is_team_member: true) }

      before { create_free_sales(20) }

      it "leaves the product alone rather than taking down our own storefront" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "when the seller is already suspended" do
      before do
        create_free_sales(20)
        seller.update!(user_risk_state: "suspended_for_tos_violation")
      end

      it "does nothing further" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "when the seller is already flagged, so the flag transition is unavailable" do
      before do
        create_free_sales(20)
        seller.update!(tos_violation_reason: "something earlier")
        seller.flag_for_tos_violation!(author_name: "admin", product_id: product.id, content: "Earlier flag")
      end

      it "still unpublishes the product and records why on the product" do
        expect do
          described_class.new.process
        end.to change { product.reload.alive? }.from(true).to(false)

        note = product.comments.where(author_name: described_class::FLAG_AUTHOR_NAME).last
        expect(note.comment_type).to eq(Comment::COMMENT_TYPE_FLAG_NOTE)
        expect(note.content).to include("20 free sales against 0 product page views")
      end
    end

    context "when the product is already unpublished" do
      before do
        create_free_sales(20)
        product.unpublish!
      end

      it "does nothing, so a re-run doesn't re-flag the same seller" do
        expect do
          described_class.new.process
        end.not_to change { seller.reload.user_risk_state }
      end
    end

    context "when the kill switch is on" do
      before do
        create_free_sales(20)
        Feature.activate(described_class::KILL_SWITCH_FEATURE)
      end

      after { Feature.deactivate(described_class::KILL_SWITCH_FEATURE) }

      it "does nothing" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "with several products in the same window" do
      let(:innocent_product) { create(:product, user: create(:user), price_cents: 0) }

      before do
        create_free_sales(20)
        create_free_sales(20, on: innocent_product)
        add_views(20, on: innocent_product)
      end

      it "acts only on the inverted one, reading views for all of them in one query" do
        expect(EsClient).to receive(:search).once.and_call_original

        expect(described_class.new.process).to eq([product.id])
        expect(innocent_product.reload.alive?).to be(true)
      end
    end
  end

  describe "thresholds" do
    # These are the numbers the detector actually ships with; the behavioural examples
    # above run against a lowered sales floor so they don't have to create 500 rows.
    it "requires real volume before the ratio counts" do
      expect(described_class::MIN_FREE_SALES_IN_WINDOW).to eq(500)
    end

    it "requires sales to be several times views" do
      expect(described_class::INVERSION_MULTIPLIER).to eq(5)
    end
  end
end
