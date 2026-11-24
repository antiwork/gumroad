# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Api::Internal::ReceiptPreviewsController do
  render_views

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Sample product", price_cents: 500) }
  let(:free_product) { create(:product, user: seller, name: "Freebie", price_cents: 0, customizable_price: true) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    it "returns the subject and rendered body from the same preview response" do
      get :show, params: { product_id: product.unique_permalink }

      expect(response).to be_successful
      json = response.parsed_body
      # Subject must be the presenter's real mail subject for this purchase preview —
      # sourced server-side alongside the body so the two cannot disagree.
      expect(json["subject"]).to eq("You bought Sample product!")
      expect(json["html"]).to include("Sample product")
    end

    it "inlines the email stylesheet but never requests one on an internal address", :skip_ssrf_stub do
      internal_stylesheet = stub_request(:get, "http://10.0.0.5:81/probe.css").to_return(status: 200, body: ".footer { border-color: #c0ffee; }")
      allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_wrap_original do |original, *names, **options|
        original.call(*names, **options).tap { _1[:stylesheets] += ["http://10.0.0.5:81/probe.css"] if names == ["email"] }
      end

      get :show, params: { product_id: product.unique_permalink }

      expect(response).to be_successful
      footer_style = Nokogiri::HTML(response.parsed_body["html"]).at_css(".email > .footer")["style"]
      expect(footer_style).to include("max-width: 600px")
      expect(footer_style).not_to include("#c0ffee")
      expect(internal_stylesheet).not_to have_been_requested
    end

    it "previews the seller's branding when their receipts carry it" do
      seller.avatar.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "smilie.png", content_type: "image/png")
      Feature.activate_user(:seller_branded_receipt, seller)

      get :show, params: { product_id: product.unique_permalink }

      header = Nokogiri::HTML(response.parsed_body["html"]).at_css(".email > .header")
      expect(header.at_css(".brand-name").text).to eq(seller.name_or_username)
      expect(header.at_css("a.wordmark")).to be_nil
    end

    it "uses the free-product subject for a free product" do
      get :show, params: { product_id: free_product.unique_permalink }

      expect(response).to be_successful
      expect(response.parsed_body["subject"]).to eq("You got Freebie!")
    end

    it "keeps the listing currency on the item line and converts the total to USD for a non-USD product" do
      nok_product = create(:product, user: seller, price_cents: 7900, price_currency_type: "nok")
      allow_any_instance_of(CurrencyHelper).to receive(:get_rate).with("nok").and_return(9.2085)
      allow_any_instance_of(CurrencyHelper).to receive(:get_rate).with(:nok).and_return(9.2085)

      get :show, params: { product_id: nok_product.unique_permalink }

      html = Capybara.string(response.parsed_body["html"])
      expect(html).to have_text("79 kr")
      expect(html).to have_text("$8.58")
      expect(html).not_to have_text("$79")
    end

    it "shows the total for a paid product" do
      get :show, params: { product_id: product.unique_permalink }

      expect(Capybara.string(response.parsed_body["html"])).to have_text("Total:")
    end

    it "omits the $0 total but keeps the order ID for a free product" do
      get :show, params: { product_id: free_product.unique_permalink }

      html = Capybara.string(response.parsed_body["html"])
      expect(html).to have_text("Order ID:")
      expect(html).not_to have_text("Total:")
    end

    it "returns a JSON error for an invalid preview" do
      allow_any_instance_of(PurchasePreview).to receive(:valid?).and_return(false)

      get :show, params: { product_id: product.unique_permalink }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to have_key("error")
    end

    it "renders successfully without invoking recommendation lookup for the synthetic preview purchase" do
      expect(RecommendedProducts::CheckoutService).not_to receive(:fetch_for_receipt)

      get :show, params: { product_id: product.unique_permalink }

      expect(response).to be_successful
    end

    describe "refund policy" do
      it "renders the product refund policy title and fine print" do
        seller.update!(refund_policy_enabled: false)
        product.update!(product_refund_policy_enabled: true)
        policy = create(:product_refund_policy, product:, max_refund_period_in_days: 14, fine_print: "Widerrufsbelehrung text")

        get :show, params: { product_id: product.unique_permalink }

        html = response.parsed_body["html"]
        expect(html).to include(policy.title)
        expect(html).to include("Widerrufsbelehrung text")
      end

      it "renders the account-level policy when it is enabled" do
        seller.update!(refund_policy_enabled: true)
        seller.refund_policy.update!(fine_print: "Account-wide fine print")

        get :show, params: { product_id: product.unique_permalink }

        expect(response.parsed_body["html"]).to include("Account-wide fine print")
      end

      it "omits the policy when the product policy is switched off" do
        seller.update!(refund_policy_enabled: false)
        product.update!(product_refund_policy_enabled: false)
        create(:product_refund_policy, product:, max_refund_period_in_days: 14, fine_print: "Hidden fine print")

        get :show, params: { product_id: product.unique_permalink }

        expect(response.parsed_body["html"]).not_to include("Hidden fine print")
      end
    end

    it "renders the custom receipt text and button label sent as strings" do
      get :show, params: { product_id: product.unique_permalink, custom_receipt_text: "Thanks for your order!", custom_view_content_button_text: "Open it" }

      expect(response).to be_successful
      html = response.parsed_body["html"]
      expect(html).to include("Thanks for your order!")
      expect(html).to include("Open it")
    end

    it "treats a non-scalar custom receipt text and button label as absent instead of raising" do
      get :show, params: { product_id: product.unique_permalink, custom_receipt_text: ["x"], custom_view_content_button_text: { "a" => "b" } }

      expect(response).to be_successful
      html = response.parsed_body["html"]
      expect(html).to include("Sample product")
      expect(html).to include("View content")
    end
  end
end
