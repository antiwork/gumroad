# frozen_string_literal: true

require "spec_helper"

describe AutoFlagInvertedSalesToViews, :elasticsearch_wait_for_refresh do
  include ProductPageViewHelpers

  before { recreate_model_index(ProductPageView) }

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 0) }
  let(:sold_at) { 1.hour.ago.beginning_of_hour + 10.minutes }

  # Scripted checkouts: many sales, few or no distinct browsers.
  def create_scripted_sales(count, on: product, browsers: 1, at: sold_at)
    count.times do |i|
      create(:free_purchase, link: on, seller: on.user, created_at: at, succeeded_at: at,
                             browser_guid: "scripted-client-#{i % browsers}")
    end
  end

  # Real buyers: one distinct browser each.
  def create_organic_sales(count, on: product, at: sold_at)
    count.times do |i|
      create(:free_purchase, link: on, seller: on.user, created_at: at, succeeded_at: at,
                             browser_guid: "organic-buyer-#{on.id}-#{i}")
    end
  end

  def add_views(count, on: product, at: sold_at)
    count.times { add_page_view(on, at.iso8601) }
  end

  describe "#process" do
    # The real floor is 500 sales in an hour, which would make every example here create 500
    # purchase rows. The shipped value is asserted separately below against the constant, so
    # the behavioural examples run against a smaller stand-in.
    before { stub_const("#{described_class}::MIN_FREE_SALES_IN_WINDOW", 3) }

    context "when free sales far exceed both page views and distinct browsers" do
      before { create_scripted_sales(20) }

      it "unpublishes the product so no further checkouts can go through" do
        expect do
          described_class.new.process
        end.to change { product.reload.alive? }.from(true).to(false)

        expect(product.reload.is_unpublished_by_admin).to be(true)
      end

      it "records all three numbers as a note on the product" do
        described_class.new.process

        note = product.comments.where(author_name: described_class::NOTE_AUTHOR_NAME).last
        expect(note.comment_type).to eq(Comment::COMMENT_TYPE_FLAG_NOTE)
        expect(note.content).to include("20 free sales against 0 product page views and only 1 distinct browsers")
      end

      # Anyone on the internet can put free checkouts through a public product, so the same
      # rows appear whether the seller ran the script or was the target of it. Acting on the
      # account off this signal alone would let an attacker get a competitor flagged.
      it "leaves the seller's account state alone, because buyers can generate this signal" do
        expect do
          described_class.new.process
        end.not_to change { seller.reload.user_risk_state }

        expect(seller.reload.tos_violation_reason).to be_nil
        expect(seller.comments.with_type_flagged).to be_empty
      end

      it "emails risk with the counts, since the account decision is a human's" do
        expect do
          described_class.new.process
        end.to have_enqueued_mail(AdminMailer, :inverted_sales_to_views_notify).with(product.id, 20, 0, 1)
      end

      it "returns the ids of the products it acted on" do
        expect(described_class.new.process).to eq([product.id])
      end
    end

    context "when the checkouts carry no browser cookie at all" do
      before do
        20.times do
          create(:free_purchase, link: product, seller:, created_at: sold_at, succeeded_at: sold_at,
                                 browser_guid: nil)
        end
      end

      it "counts that as zero distinct clients and acts, rather than skipping for lack of data" do
        expect do
          described_class.new.process
        end.to change { product.reload.alive? }.from(true).to(false)
      end
    end

    # This is the false positive the detector most has to avoid: `/l/<permalink>?wanted=true`
    # redirects straight to checkout without rendering the product page, so a legitimate lead
    # magnet blasted to a newsletter records lots of sales and almost no views.
    context "when a lead magnet is mailed to a big list, so there are sales but no page views" do
      before { create_organic_sales(20) }

      it "leaves the product alone, because the sales came from distinct browsers" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "when views keep pace with sales" do
      before do
        create_scripted_sales(20)
        add_views(20)
      end

      it "leaves the product alone" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "when sales exceed views but not by the inversion multiplier" do
      before do
        create_scripted_sales(20)
        # 20 sales against 8 views is 2.5x, under the 5x bar — the kind of gap a product sold
        # through an embed or a direct link legitimately produces.
        add_views(8)
      end

      it "leaves the product alone" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    # Buying a bundle creates a separate $0 purchase row for every product inside it, and the
    # buyer only ever visits the bundle's page. Without the exclusion, a bundle selling well
    # would take down every product it contains.
    context "when the sales are bundle child purchases" do
      before do
        20.times do |i|
          create(:free_purchase, link: product, seller:, created_at: sold_at, succeeded_at: sold_at,
                                 is_bundle_product_purchase: true, browser_guid: "bundle-client-#{i % 2}")
        end
      end

      it "leaves the product alone, because the views live on the bundle's page" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "when the product is under the minimum sales volume" do
      before { create_scripted_sales(2) }

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
          purchase = create(:free_purchase, link: paid_product, seller:, created_at: sold_at,
                                            browser_guid: "scripted-client-0")
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
      before { create_scripted_sales(20, at: 5.hours.ago) }

      it "leaves the product alone" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    # If Elasticsearch indexing lags, the search succeeds and returns zero views for everything,
    # so every busy free product looks inverted at once. That is far more likely to be a broken
    # read than that many simultaneous incidents.
    context "when more products trip in one run than a real incident would produce" do
      before do
        stub_const("#{described_class}::MAX_PRODUCTS_PER_RUN", 2)
        3.times do
          other = create(:product, user: create(:user), price_cents: 0)
          create_scripted_sales(20, on: other)
        end
      end

      it "takes no action at all" do
        expect(described_class.new.process).to eq([])
        expect(Link.all.all?(&:alive?)).to be(true)
      end

      it "tells risk to go look instead" do
        expect(ErrorNotifier).to receive(:notify).with(/more likely a broken page-view read/, hash_including(:context))
        described_class.new.process
      end
    end

    context "when the seller is a team member" do
      let(:seller) { create(:user, is_team_member: true) }

      before { create_scripted_sales(20) }

      it "leaves the product alone rather than taking down our own storefront" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "when the seller is already suspended" do
      before do
        create_scripted_sales(20)
        seller.update!(user_risk_state: "suspended_for_tos_violation")
      end

      it "does nothing further" do
        expect do
          described_class.new.process
        end.not_to change { product.reload.alive? }
      end
    end

    context "when the seller was already flagged by someone else" do
      before do
        create_scripted_sales(20)
        seller.update!(tos_violation_reason: "something earlier")
        seller.flag_for_tos_violation!(author_name: "admin", product_id: product.id, content: "Earlier flag")
      end

      it "takes the product down without touching the existing account state" do
        expect do
          described_class.new.process
        end.to change { product.reload.alive? }.from(true).to(false)

        expect(seller.reload.user_risk_state).to eq("flagged_for_tos_violation")
        expect(seller.tos_violation_reason).to eq("something earlier")
        note = product.comments.where(author_name: described_class::NOTE_AUTHOR_NAME).last
        expect(note.content).to include("20 free sales against 0 product page views")
      end
    end

    context "when acting on one product raises" do
      let(:other_product) { create(:product, user: create(:user), price_cents: 0) }

      before do
        create_scripted_sales(20)
        create_scripted_sales(20, on: other_product)
        allow_any_instance_of(Link).to receive(:unpublish!).and_wrap_original do |original, **kwargs|
          raise ActiveRecord::RecordInvalid if original.receiver.id == product.id
          original.call(**kwargs)
        end
      end

      it "reports it and keeps going, rather than aborting the whole sweep" do
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::RecordInvalid), hash_including(:context))

        expect(described_class.new.process).to eq([other_product.id])
        expect(other_product.reload.alive?).to be(false)
      end
    end

    context "when the product is already unpublished" do
      before do
        create_scripted_sales(20)
        product.unpublish!
      end

      it "does nothing, so a re-run doesn't pile up notes and emails on the same product" do
        expect do
          described_class.new.process
        end.not_to change { product.comments.count }
      end
    end

    context "when the kill switch is on" do
      before do
        create_scripted_sales(20)
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
        create_scripted_sales(20)
        create_organic_sales(20, on: innocent_product)
      end

      it "acts only on the scripted one, reading views for all of them in one query" do
        expect(EsClient).to receive(:search).once.and_call_original

        expect(described_class.new.process).to eq([product.id])
        expect(innocent_product.reload.alive?).to be(true)
      end
    end
  end

  describe "thresholds" do
    # These are the numbers the detector actually ships with; the behavioural examples above
    # run against a lowered sales floor so they don't have to create 500 rows.
    it "requires real volume before anything is considered" do
      expect(described_class::MIN_FREE_SALES_IN_WINDOW).to eq(500)
    end

    it "requires sales to be several times views" do
      expect(described_class::INVERSION_MULTIPLIER).to eq(5)
    end

    it "requires each distinct browser to account for several sales" do
      expect(described_class::MIN_SALES_PER_DISTINCT_CLIENT).to eq(5)
    end

    it "refuses to act on more than a handful of products in one run" do
      expect(described_class::MAX_PRODUCTS_PER_RUN).to eq(5)
    end
  end
end
