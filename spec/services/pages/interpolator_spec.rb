# frozen_string_literal: true

require "spec_helper"

describe Pages::Interpolator do
  let(:product) { create(:product, name: "Test Product", description: "<p>Real <strong>description</strong></p>", price_cents: 1500) }

  describe ".interpolate" do
    it "replaces data-gumroad-field='name' with the product name" do
      html = %(<h1 data-gumroad-field="name">placeholder</h1>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include("<h1 data-gumroad-field=\"name\">Test Product</h1>")
      expect(result).not_to include("placeholder")
    end

    it "replaces data-gumroad-field='price' with the formatted price" do
      html = %(<span data-gumroad-field="price">$0</span>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include(product.price_formatted_verbose)
    end

    describe "review fields" do
      # Real reviews rather than a hand-set stat row: reviews_count and average_rating are both
      # derived columns written by ProductReviewStat's own SQL, so setting one by hand produces a
      # shape production cannot reach (count 4, average 0.0) and the spec asserts a lie.
      def review!(product, rating)
        create(:product_review, purchase: create(:purchase, link: product), rating:)
      end

      let(:reviewed) do
        create(:product, name: "Reviewed").tap do |p|
          2.times { review!(p, 4) }
          2.times { review!(p, 5) }
        end
      end

      it "writes the average rating and the review count" do
        html = %(<span data-gumroad-field="rating">0</span><span data-gumroad-field="review-count">no reviews</span>)

        result = described_class.interpolate(html, product: reviewed.reload)

        expect(result).to include(%(<span data-gumroad-field="rating">4.5</span>))
        expect(result).to include(%(<span data-gumroad-field="review-count">4</span>))
        expect(result).not_to include("no reviews")
      end

      it "leaves the element untouched when the seller has reviews hidden" do
        reviewed.update!(display_product_reviews: false)
        html = %(<span data-gumroad-field="rating">Loved by our customers</span>)

        result = described_class.interpolate(html, product: reviewed.reload)

        expect(result).to include("Loved by our customers")
        expect(result).not_to include("4.5")
      end

      it "leaves the element untouched when the product has no reviews" do
        html = %(<span data-gumroad-field="review-count">Be the first to review</span>)

        result = described_class.interpolate(html, product: product)

        expect(result).to include("Be the first to review")
        expect(result).not_to include(%(<span data-gumroad-field="review-count">0</span>))
      end

      # The native page renders the rating as a JSON number, so 4.0 reaches the buyer as "4".
      it "renders a whole-number average without a trailing zero" do
        whole = create(:product).tap { |p| 2.times { review!(p, 4) } }

        result = described_class.interpolate(%(<span data-gumroad-field="rating">x</span>), product: whole.reload)

        expect(result).to include(%(<span data-gumroad-field="rating">4</span>))
      end

      it "computes the review summary once even when the markers repeat" do
        product = reviewed.reload
        expect(product).to receive(:rating_stats).once.and_call_original
        html = %(<span data-gumroad-field="rating">x</span><span data-gumroad-field="review-count">x</span>) * 2

        result = described_class.interpolate(html, product:)

        expect(result.scan(%(<span data-gumroad-field="rating">4.5</span>)).size).to eq(2)
        expect(result.scan(%(<span data-gumroad-field="review-count">4</span>)).size).to eq(2)
      end

      # Bundles carry their own reviews now (#6078), so the page shows the bundle's row alone
      # rather than merging in what its contents earned on their own pages.
      it "uses only the bundle's own reviews for a bundle" do
        bundle = create(:product, :bundle, name: "Bundle")
        inner = create(:product, user: bundle.user)
        3.times { review!(inner, 5) }
        create(:bundle_product, bundle:, product: inner)
        review!(bundle, 3)

        result = described_class.interpolate(%(<span data-gumroad-field="review-count">x</span>), product: bundle.reload)

        expect(result).to include(%(<span data-gumroad-field="review-count">1</span>))
      end
    end

    # The native /l/ page this markup replaces auto-applies the default offer code
    # (BestOfferCodeService), so the undiscounted set price would sit next to a checkout that
    # charges less.
    it "quotes the price a first-time buyer pays, with the default offer code applied" do
      offer_code = product.user.offer_codes.create!(code: "half", amount_percentage: 50, products: [product])
      product.update!(default_offer_code: offer_code)
      html = %(<span data-gumroad-field="price">$0</span>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include(">$7.50<")
    end

    # Without for_default_duration the amount is the cheapest across every enabled recurrence —
    # here $4 monthly on a yearly-default membership, a price the page's own buy flow never
    # charges at its default selection.
    it "quotes a tiered membership at its default recurrence" do
      membership = create(:membership_product_with_preset_tiered_pricing,
                          subscription_duration: :yearly,
                          recurrence_price_values: [
                            { monthly: { enabled: true, price: 4 }, yearly: { enabled: true, price: 40 } },
                            { monthly: { enabled: true, price: 9 }, yearly: { enabled: true, price: 90 } },
                          ])
      html = %(<span data-gumroad-field="price"></span>)

      result = described_class.interpolate(html, product: membership)

      expect(result).to include(">$40+ a year<")
    end

    it "labels a fixed-length membership's term like the native page" do
      membership = create(:membership_product, price_cents: 500)
      membership.update!(duration_in_months: 1)
      html = %(<span data-gumroad-field="price"></span>)

      result = described_class.interpolate(html, product: membership)

      expect(result).to include(">$5 once<")
    end

    it "preserves the description's paragraph/heading structure instead of collapsing it to plain text" do
      product.update!(description: "<h1>Title</h1><p>First paragraph.</p><p>Second <strong>paragraph</strong>.</p>")
      html = %(<div data-gumroad-field="description">placeholder</div>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include("<h1>Title</h1>")
      expect(result).to include("<p>First paragraph.</p>")
      expect(result).to include("<p>Second <strong>paragraph</strong>.</p>")
      expect(result).not_to include("placeholder")
    end

    it "strips tags outside the description allowlist but keeps their text" do
      product.update!(description: %(<p>Safe</p><script>alert("xss")</script><table><tr><td>cell</td></tr></table>))
      html = %(<div data-gumroad-field="description"></div>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include("<p>Safe</p>")
      expect(result).not_to include("<script>")
      expect(result).not_to include("<table>")
      expect(result).to include("cell")
    end

    it "prepares <a data-gumroad-action='buy'> for the delegated checkout bridge" do
      html = %(<a data-gumroad-action="buy" href="#">Buy</a>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include(%(href="/l/#{product.unique_permalink}?wanted=true"))
      expect(result).to include(%(data-gumroad-checkout-params="{}"))
      expect(result).not_to include("onclick")
    end

    it "leaves unknown field markers untouched (graceful fallback)" do
      html = %(<span data-gumroad-field="not-a-real-field">fallback text</span>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include(">fallback text<")
    end

    it "html-escapes interpolated values to prevent XSS" do
      product.update!(name: %(<script>alert("xss")</script>))
      html = %(<h1 data-gumroad-field="name"></h1>)

      result = described_class.interpolate(html, product: product)

      expect(result).not_to include("<script>")
      expect(result).to include("&lt;script&gt;")
    end

    it "interpolates multiple markers in the same document" do
      html = %(
        <h1 data-gumroad-field="name"></h1>
        <span data-gumroad-field="price"></span>
        <a data-gumroad-action="buy" href="#">Buy</a>
      )

      result = described_class.interpolate(html, product: product)

      expect(result).to include("Test Product")
      expect(result).to include(product.price_formatted_verbose)
      expect(result).to include("?wanted=true")
    end

    it "returns the input unchanged when there are no markers" do
      html = "<section><h1>Static page</h1><p>no markers here</p></section>"

      result = described_class.interpolate(html, product: product)

      expect(result).to include("Static page")
      expect(result).to include("no markers here")
    end

    it "returns blank input as-is" do
      expect(described_class.interpolate("", product: product)).to eq("")
      expect(described_class.interpolate(nil, product: product)).to be_nil
    end

    it "prepares non-anchor buy elements without converting them to anchors" do
      html = %(<button data-gumroad-action="buy">Buy</button>)

      result = described_class.interpolate(html, product: product)

      expect(result).to include(%(data-gumroad-checkout-params="{}"))
      expect(result).not_to include("onclick")
      expect(result).to include("<button")
      expect(result).not_to include("<a")
      expect(result).not_to include("href=")
    end

    it "bakes valid variant/quantity selection into the anchor href and the checkout-params payload" do
      product = create(:product_with_digital_versions, quantity_enabled: true)
      product.alive_variants.first.update!(name: "Pro plan")

      result = described_class.interpolate(
        %(<a data-gumroad-action="buy" data-gumroad-option="Pro plan" data-gumroad-quantity="2">Buy Pro</a>),
        product: product
      )

      # href encodes the validated selection so SEO/no-JS still lands on the right checkout
      expect(result).to include(%(href="/l/#{product.unique_permalink}?wanted=true&amp;variant=Pro+plan&amp;quantity=2"))
      # postMessage payload mirrors the selection. The JSON contains double quotes,
      # so Nokogiri serializes the attribute single-quoted with the inner quotes
      # left literal — the browser's dataset read + JSON.parse handle it fine.
      expect(result).to include(%(data-gumroad-checkout-params='{"variant":"Pro plan","quantity":2}'))
    end

    it "silently drops selection attributes the product can't honor (lenient fallback)" do
      product = create(:product, price_cents: 100) # simple product, no variants/PWYW/quantity/recurrence

      result = described_class.interpolate(
        %(<a data-gumroad-action="buy"
             data-gumroad-option="Mystery"
             data-gumroad-quantity="9"
             data-gumroad-price="99.99"
             data-gumroad-recurrence="yearly">Buy</a>),
        product: product
      )

      # No selection survives: the href is the default checkout and the payload is
      # empty. The data-gumroad-* attributes stay on the element (the interpolator
      # reads them, it doesn't strip them), so assert on the href/payload rather
      # than the absence of the attribute names.
      expect(result).to include(%(href="/l/#{product.unique_permalink}?wanted=true"))
      expect(result).not_to match(/href="[^"]*&amp;(variant|option|quantity|price|recurrence)=/)
      expect(result).to include(%(data-gumroad-checkout-params="{}"))
    end
  end

  describe ".interpolate_profile" do
    let(:seller) { create(:user, name: "Jane Doe", bio: "Maker of things") }

    it "replaces data-gumroad-field='name' with the seller's display name" do
      html = %(<h1 data-gumroad-field="name">placeholder</h1>)

      result = described_class.interpolate_profile(html, profile: seller)

      expect(result).to include("<h1 data-gumroad-field=\"name\">Jane Doe</h1>")
      expect(result).not_to include("placeholder")
    end

    it "replaces data-gumroad-field='bio' with the seller's bio" do
      html = %(<p data-gumroad-field="bio">placeholder</p>)

      result = described_class.interpolate_profile(html, profile: seller)

      expect(result).to include("Maker of things")
      expect(result).not_to include("placeholder")
    end

    it "falls back to the username when the seller has no name" do
      seller.update!(name: nil, username: "janedoe")
      html = %(<h1 data-gumroad-field="name"></h1>)

      result = described_class.interpolate_profile(html, profile: seller)

      expect(result).to include(">janedoe<")
    end

    it "does not rewrite buy elements (profiles have no checkout)" do
      html = %(<a data-gumroad-action="buy" href="/elsewhere">Link</a>)

      result = described_class.interpolate_profile(html, profile: seller)

      expect(result).to include(%(href="/elsewhere"))
      expect(result).not_to include("wanted=true")
      expect(result).not_to include("data-gumroad-checkout-params")
    end

    it "html-escapes interpolated values to prevent XSS" do
      seller.update!(name: %(<script>alert("xss")</script>))
      html = %(<h1 data-gumroad-field="name"></h1>)

      result = described_class.interpolate_profile(html, profile: seller)

      expect(result).not_to include("<script>")
      expect(result).to include("&lt;script&gt;")
    end

    it "leaves unknown field markers untouched (graceful fallback)" do
      html = %(<span data-gumroad-field="price">fallback text</span>)

      result = described_class.interpolate_profile(html, profile: seller)

      expect(result).to include(">fallback text<")
    end

    it "returns blank input as-is" do
      expect(described_class.interpolate_profile("", profile: seller)).to eq("")
      expect(described_class.interpolate_profile(nil, profile: seller)).to be_nil
    end

    describe "product-scoped price fields" do
      let(:prices) do
        { "quicklauncher" => { price: "€11.20", price_cents: 1120, currency_code: "eur", localized: true } }
      end

      it "writes the product's price into an element scoped to its permalink" do
        html = %(<span data-gumroad-product="quicklauncher" data-gumroad-field="price">$14</span>)

        result = described_class.interpolate_profile(html, profile: seller, prices:)

        expect(result).to include(">€11.20<")
        expect(result).not_to include("$14")
      end

      it "writes the currency the price is in, uppercased for display" do
        html = %(<span data-gumroad-product="quicklauncher" data-gumroad-field="currency">USD</span>)

        result = described_class.interpolate_profile(html, profile: seller, prices:)

        expect(result).to include(">EUR<")
      end

      it "writes the pre-discount price into an original-price element" do
        discounted = { "quicklauncher" => { price: "€5.60", original_price: "€11.20", currency_code: "eur" } }
        html = %(<s data-gumroad-product="quicklauncher" data-gumroad-field="original-price"></s>)

        result = described_class.interpolate_profile(html, profile: seller, prices: discounted)

        expect(result).to include(">€11.20<")
      end

      it "leaves an original-price element empty when the product is not discounted" do
        html = %(<s data-gumroad-product="quicklauncher" data-gumroad-field="original-price"></s>)

        result = described_class.interpolate_profile(html, profile: seller, prices:)

        expect(result).to include(%(data-gumroad-field="original-price"></s>))
      end

      it "leaves the element's own text alone when the permalink is unknown" do
        html = %(<span data-gumroad-product="gone" data-gumroad-field="price">$14</span>)

        result = described_class.interpolate_profile(html, profile: seller, prices:)

        expect(result).to include(">$14<")
      end

      it "leaves the element's own text alone when no prices are supplied" do
        html = %(<span data-gumroad-product="quicklauncher" data-gumroad-field="price">$14</span>)

        expect(described_class.interpolate_profile(html, profile: seller)).to include(">$14<")
      end

      # Without this the seller's name would be written into every product card that reused
      # data-gumroad-field="name" inside a product-scoped element.
      it "does not answer a product-scoped element with a seller-level field" do
        html = %(<h2 data-gumroad-product="quicklauncher" data-gumroad-field="name">Quicklauncher</h2>)

        result = described_class.interpolate_profile(html, profile: seller, prices:)

        expect(result).to include(">Quicklauncher<")
        expect(result).not_to include("Jane Doe")
      end

      # The attribute's presence is what scopes — the preview listener excludes any node
      # carrying it, so a valueless marker must not fall back to profile fields either.
      it "treats an empty product marker as product-scoped, keeping its fallback text" do
        html = %(<h2 data-gumroad-product="" data-gumroad-field="name">Quicklauncher</h2>)

        result = described_class.interpolate_profile(html, profile: seller, prices:)

        expect(result).to include(">Quicklauncher<")
        expect(result).not_to include("Jane Doe")
      end

      it "still fills seller-level fields on elements with no product scope" do
        html = %(<h1 data-gumroad-field="name"></h1><span data-gumroad-product="quicklauncher" data-gumroad-field="price"></span>)

        result = described_class.interpolate_profile(html, profile: seller, prices:)

        expect(result).to include(">Jane Doe<")
        expect(result).to include(">€11.20<")
      end

      it "html-escapes the interpolated price" do
        html = %(<span data-gumroad-product="x" data-gumroad-field="price"></span>)
        malicious = { "x" => { price: %(<script>alert("xss")</script>), currency_code: "usd" } }

        result = described_class.interpolate_profile(html, profile: seller, prices: malicious)

        expect(result).not_to include("<script>")
        expect(result).to include("&lt;script&gt;")
      end
    end
  end
end
