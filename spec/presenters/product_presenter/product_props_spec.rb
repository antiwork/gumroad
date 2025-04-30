# frozen_string_literal: true

require "spec_helper"

describe ProductPresenter::ProductProps do
  include Rails.application.routes.url_helpers
  include Capybara::RSpecMatchers

  let(:presenter) { described_class.new(product:) }

  describe "#props", :vcr do
    let(:seller) { create(:user, name: "Testy", username: "testy", created_at: 60.days.ago) }
    let(:buyer) { create(:user) }
    let(:request) { OpenStruct.new(remote_ip: "12.12.128.128", host: "example.com", host_with_port: "example.com") }

    before do
      create(:payment_completed, user: seller)
      create(:custom_domain, user: seller, domain: "www.example.com")
      allow(request).to receive(:cookie_jar).and_return({})
    end

    context "membership product" do
      let(:product) { create(:membership_product, unique_permalink: "test", name: "hello", user: seller, price_cents: 200) }
      let(:offer_code) { create(:offer_code, products: [product], valid_at: 1.day.ago, expires_at: 1.day.from_now, minimum_quantity: 1, duration_in_billing_cycles: 1) }
      let(:purchase) { create(:membership_purchase, :with_review, link: product, email: buyer.email) }
      let!(:asset_preview) { create(:asset_preview, link: product) }

      context "when requested from gumroad domain" do
        let(:request) { double("request") }
        before do
          allow(request).to receive(:remote_ip).and_return("12.12.128.128")
          allow(request).to receive(:host).and_return("http://testy.test.gumroad.com")
          allow(request).to receive(:host_with_port).and_return("http://testy.test.gumroad.com:1234")
          allow(request).to receive(:cookie_jar).and_return({ _gumroad_guid: purchase.browser_guid })
        end
        let(:pundit_user) { SellerContext.new(user: buyer, seller: buyer) }


        it "returns properties for the product page" do
          product.save_custom_attributes(
            [
              { "name" => "Attribute 1", "value" => "Value 1" },
              { "name" => "Attribute 2", "value" => "Value 2" }
            ]
          )

          expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:, recommended_by: "discover", discount_code: offer_code.code)).to eq(
            product: {
              id: product.external_id,
              price_cents: 0,
              **ProductPresenter::InstallmentPlanProps.new(product:).props,
              covers: [product.asset_previews.first.as_json],
              currency_code: Currency::USD,
              custom_view_content_button_text: nil,
              custom_button_text_option: nil,
              description_html: "This is a collection of works spanning 1984 — 1994, while I spent time in a shack in the Andes.",
              pwyw: nil,
              is_sales_limited: false,
              is_tiered_membership: true,
              is_legacy_subscription: false,
              long_url: short_link_url(product.unique_permalink, host: seller.subdomain_with_protocol),
              main_cover_id: asset_preview.guid,
              name: "hello",
              permalink: "test",
              preorder: nil,
              duration_in_months: nil,
              quantity_remaining: nil,
              ratings: {
                count: 1,
                average: 5,
                percentages: [0, 0, 0, 0, 100],
              },
              seller: {
                avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
                id: seller.external_id,
                name: "Testy",
                profile_url: seller.profile_url(recommended_by: "discover"),
              },
              collaborating_user: nil,
              is_compliance_blocked: false,
              is_published: true,
              is_physical: false,
              attributes: [
                { name: "Attribute 1", value: "Value 1" },
                { name: "Attribute 2", value: "Value 2" }
              ],
              free_trial: nil,
              is_quantity_enabled: false,
              is_multiseat_license: false,
              native_type: "membership",
              is_stream_only: false,
              streamable: false,
              options: [{
                id: product.variant_categories[0].variants[0].external_id,
                description: "",
                name: "hello",
                is_pwyw: false,
                price_difference_cents: nil,
                quantity_left: nil,
                recurrence_price_values: {
                  "monthly" => {
                    price_cents: 200,
                    suggested_price_cents: nil
                  }
                },
                duration_in_minutes: nil,
              }],
              rental: nil,
              recurrences: {
                default: "monthly",
                enabled: [{ id: product.prices.alive.first.external_id, recurrence: "monthly", price_cents: 0 }]
              },
              rental_price_cents: nil,
              sales_count: nil,
              summary: nil,
              thumbnail_url: nil,
              analytics: product.analytics_data,
              has_third_party_analytics: false,
              ppp_details: nil,
              can_edit: false,
              refund_policy: {
                title: "30-day money back guarantee",
                fine_print: nil,
                updated_at: product.user.refund_policy.updated_at.to_date
              },
              bundle_products: [],
              public_files: [],
              audio_previews_enabled: false,
            },
            discount_code: {
              valid: true,
              code: "sxsw",
              discount: {
                type: "fixed",
                cents: 100,
                product_ids: [product.external_id],
                expires_at: offer_code.expires_at,
                minimum_quantity: 1,
                duration_in_billing_cycles: 1,
                minimum_amount_cents: nil,
              },
            },
            purchase: {
              content_url: nil,
              created_at: purchase.created_at,
              id: purchase.external_id,
              email_digest: purchase.email_digest,
              membership: {
                manage_url: manage_subscription_url(purchase.subscription.external_id, host: DOMAIN),
                tier_name: "hello",
                tier_description: nil
              },
              review: ProductReviewPresenter.new(purchase.product_review).review_form_props,
              should_show_receipt: true,
              is_gift_receiver_purchase: false,
              show_view_content_button_on_product_page: false,
              subscription_has_lapsed: false,
              total_price_including_tax_and_shipping: "$0 a month"
            },
            wishlists: [],
          )
        end

        context "when the user has read-only access" do
          let(:support_for_seller) { create(:user, username: "supportforseller") }
          let(:pundit_user) { SellerContext.new(user: support_for_seller, seller:) }

          before do
            create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
          end

          it "sets can_edit to false" do
            expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:)[:product][:can_edit]).to eq(false)
          end
        end

        context "when product refund policy setting is enabled" do
          let!(:product_refund_policy) do
            create(:product_refund_policy, title: "Refund policy", fine_print: "This is a product-level refund policy", product:, seller:)
          end

          before do
            product.user.update!(refund_policy_enabled: false)
            product.update!(product_refund_policy_enabled: true)
          end

          it "returns the product-level refund policy" do
            expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:)[:product][:refund_policy]).to eq(
              {
                title: product_refund_policy.title,
                fine_print: "<p>This is a product-level refund policy</p>",
                updated_at: product_refund_policy.updated_at.to_date
              }
            )
          end

          context "when the fine_print is empty" do
            before do
              product_refund_policy.update!(fine_print: "")
            end

            it "returns the refund policy" do
              expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:)[:product][:refund_policy]).to eq(
                {
                  title: product_refund_policy.title,
                  fine_print: nil,
                  updated_at: product_refund_policy.updated_at.to_date
                }
              )
            end
          end

          context "when account-level refund policy setting is enabled" do
            before do
              seller.update!(refund_policy_enabled: true)
              seller.refund_policy.update!(fine_print: "This is a seller-level refund policy")
            end

            it "returns the seller-level refund policy" do
              expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:)[:product][:refund_policy]).to eq(
                {
                  title: seller.refund_policy.title,
                  fine_print: "<p>This is a seller-level refund policy</p>",
                  updated_at: seller.refund_policy.updated_at.to_date
                }
              )
            end

            context "when seller_refund_policy_disabled_for_all feature flag is set to true" do
              before do
                Feature.activate(:seller_refund_policy_disabled_for_all)
              end

              it "returns the product-level refund policy" do
                expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:)[:product][:refund_policy]).to eq(
                  {
                    title: product_refund_policy.title,
                    fine_print: "<p>This is a product-level refund policy</p>",
                    updated_at: product_refund_policy.updated_at.to_date
                  }
                )
              end
            end
          end
        end

        context "with invalid offer code" do
          it "returns an error if the offer code is sold out" do
            offer_code.update!(max_purchase_count: 0)

            expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:, discount_code: offer_code.code)[:discount_code]).to eq({ valid: false, error_code: :sold_out })
          end

          it "returns an error if the offer code doesn't exist" do
            expect(described_class.new(product:).props(seller_custom_domain_url: nil, request:, pundit_user: nil, discount_code: "notreal")[:discount_code]).to eq({ valid: false, error_code: :invalid_offer })
          end
        end
      end
    end

    context "digital versioned product" do
      let(:product) { create(:product_with_digital_versions, native_type: Link::NATIVE_TYPE_COMMISSION, unique_permalink: "test", name: "hello", user: seller, price_cents: 200) }
      let(:purchase) { create(:membership_purchase, link: product, email: buyer.email) }
      let!(:review) { create(:product_review, purchase:, rating: 5, message: "This is my review!") }

      context "when requested from gumroad domain" do
        let(:request) { double("request") }
        before do
          allow(request).to receive(:remote_ip).and_return("12.12.128.128")
          allow(request).to receive(:host).and_return("http://testy.test.gumroad.com")
          allow(request).to receive(:host_with_port).and_return("http://testy.test.gumroad.com:1234")
          allow(request).to receive(:cookie_jar).and_return({ _gumroad_guid: purchase.browser_guid })
        end
        let(:pundit_user) { SellerContext.new(user: buyer, seller: buyer) }

        it "returns properties for the product page" do
          expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:, recommended_by: "profile")).to eq(
            product: {
              id: product.external_id,
              price_cents: 200,
              **ProductPresenter::InstallmentPlanProps.new(product:).props,
              covers: [],
              currency_code: Currency::USD,
              custom_view_content_button_text: nil,
              custom_button_text_option: nil,
              description_html: "This is a collection of works spanning 1984 — 1994, while I spent time in a shack in the Andes.",
              pwyw: nil,
              is_sales_limited: false,
              is_tiered_membership: false,
              is_legacy_subscription: false,
              long_url: short_link_url(product.unique_permalink, host: seller.subdomain_with_protocol),
              main_cover_id: nil,
              name: "hello",
              permalink: "test",
              preorder: nil,
              duration_in_months: nil,
              quantity_remaining: nil,
              ratings: {
                count: 1,
                average: 5,
                percentages: [0, 0, 0, 0, 100],
              },
              seller: {
                avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
                id: seller.external_id,
                name: "Testy",
                profile_url: seller.profile_url(recommended_by: "profile"),
              },
              collaborating_user: nil,
              is_compliance_blocked: false,
              is_published: true,
              is_physical: false,
              attributes: [],
              free_trial: nil,
              is_quantity_enabled: false,
              is_multiseat_license: false,
              native_type: "commission",
              is_stream_only: false,
              streamable: false,
              options: [
                {
                  id: product.variant_categories[0].variants[0].external_id,
                  description: "",
                  name: "Untitled 1",
                  is_pwyw: false,
                  price_difference_cents: 0,
                  quantity_left: nil,
                  recurrence_price_values: nil,
                  duration_in_minutes: nil,
                },
                {
                  id: product.variant_categories[0].variants[1].external_id,
                  description: "",
                  name: "Untitled 2",
                  is_pwyw: false,
                  price_difference_cents: 0,
                  quantity_left: nil,
                  recurrence_price_values: nil,
                  duration_in_minutes: nil,
                }
              ],
              rental: nil,
              recurrences: nil,
              rental_price_cents: nil,
              sales_count: nil,
              summary: nil,
              thumbnail_url: nil,
              analytics: product.analytics_data,
              has_third_party_analytics: false,
              ppp_details: nil,
              can_edit: false,
              refund_policy: {
                title: product.user.refund_policy.title,
                fine_print: product.user.refund_policy.fine_print,
                updated_at: product.user.refund_policy.updated_at.to_date
              },
              bundle_products: [],
              public_files: [],
              audio_previews_enabled: false,
            },
            discount_code: nil,
            purchase: {
              content_url: nil,
              id: purchase.external_id,
              email_digest: purchase.email_digest,
              created_at: purchase.created_at,
              membership: nil,
              review: ProductReviewPresenter.new(purchase.product_review).review_form_props,
              should_show_receipt: true,
              is_gift_receiver_purchase: false,
              show_view_content_button_on_product_page: false,
              subscription_has_lapsed: false,
              total_price_including_tax_and_shipping: "$2"
            },
            wishlists: [],
          )
        end

        it "handles users without a username set" do
          seller.update!(username: nil)

          expect(described_class.new(product:).props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:seller]).to be_nil
        end
      end
    end

    context "bundle product" do
      let(:bundle) { create(:product, user: seller, is_bundle: true) }

      before do
        create(:bundle_product, bundle:, product: create(:product, user: seller), quantity: 2, position: 1)
        versioned_product = create(:product_with_digital_versions, user: seller)
        versioned_product.alive_variants.second.update(price_difference_cents: 200)
        create(:bundle_product, bundle:, product: versioned_product, variant: versioned_product.alive_variants.second, position: 0)
        bundle.reload
      end

      it "sets bundle_products correctly" do
        expect(described_class.new(product: bundle).props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product][:bundle_products]).to eq(
          [
            {
              currency_code: Currency::USD,
              id: bundle.bundle_products.second.product.external_id,
              name: "The Works of Edgar Gumstein",
              native_type: "digital",
              price: 300,
              quantity: 1,
              ratings: { average: 0, count: 0 },
              thumbnail_url: nil,
              url: short_link_url(bundle.bundle_products.second.product.unique_permalink, host: request[:host]),
              variant: "Untitled 2",
            },
            {
              currency_code: Currency::USD,
              id: bundle.bundle_products.first.product.external_id,
              name: "The Works of Edgar Gumstein",
              native_type: "digital",
              price: 200,
              quantity: 2,
              ratings: { average: 0, count: 0 },
              thumbnail_url: nil,
              url: short_link_url(bundle.bundle_products.first.product.unique_permalink, host: request[:host]),
              variant: nil,
            },
          ]
        )
      end
    end

    describe "collaborators" do
      let(:product) { create(:product, user: seller, is_collab: true) }
      let(:pundit_user) { SellerContext.new(user: product.user, seller: product.user) }
      let!(:collaborator) { create(:collaborator, seller:) }
      let!(:product_affiliate) { create(:product_affiliate, affiliate: collaborator, product:, dont_show_as_co_creator: false) }

      context "apply_to_all_products is true" do
        context "collaborator dont_show_as_co_creator is false" do
          it "includes the collaborating user" do
            expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:)[:product][:collaborating_user]).to eq(
              {
                avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
                id: collaborator.affiliate_user.external_id,
                name: collaborator.affiliate_user.username,
                profile_url: collaborator.affiliate_user.profile_url,
              }
            )
          end
        end

        context "collaborator dont_show_as_co_creator is true" do
          before { collaborator.update!(dont_show_as_co_creator: true) }

          it "does not include the collaborating user" do
            expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:)[:product][:collaborating_user]).to be_nil
          end
        end
      end

      context "apply_to_all_products is false" do
        before { collaborator.update!(apply_to_all_products: false) }

        context "product affiliate dont_show_as_co_creator is false" do
          it "includes the collaborating user" do
            expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:)[:product][:collaborating_user]).to eq(
              {
                avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
                id: collaborator.affiliate_user.external_id,
                name: collaborator.affiliate_user.username,
                profile_url: collaborator.affiliate_user.profile_url,
              }
            )
          end
        end

        context "product affiliate dont_show_as_co_creator is true" do
          before { product_affiliate.update!(dont_show_as_co_creator: true) }

          it "does not include the collaborating user" do
            expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:)[:product][:collaborating_user]).to be_nil
          end
        end
      end
    end

    it "caches sales_count and tracks cache hits/misses", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      product = create(:product, user: seller)
      presenter = described_class.new(product:)

      metrics_key = described_class::SALES_COUNT_CACHE_METRICS_KEY
      $redis.del(metrics_key)

      expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product][:sales_count]).to eq(nil)
      expect($redis.hgetall(metrics_key)).to eq({})

      product.update!(should_show_sales_count: true)

      expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product][:sales_count]).to eq(0)
      expect($redis.hgetall(metrics_key)).to eq("misses" => "1")

      expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product][:sales_count]).to eq(0)
      expect($redis.hgetall(metrics_key)).to eq("misses" => "1", "hits" => "1")

      create(:purchase, link: product)

      expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product][:sales_count]).to eq(1)
      expect($redis.hgetall(metrics_key)).to eq("misses" => "2", "hits" => "1")

      expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product][:sales_count]).to eq(1)
      expect($redis.hgetall(metrics_key)).to eq("misses" => "2", "hits" => "2")
    end

    it "includes free downloads in the sales_count for products with paid variants", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      product = create(:product, user: seller, should_show_sales_count: true, price_cents: 0)
      presenter = described_class.new(product:)

      category = create(:variant_category, link: product)
      create(:variant, variant_category: category, price_difference_cents: 200)

      create(:free_purchase, link: product)
      create_list(:purchase, 2, link: product, price_cents: 200)

      expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product][:sales_count]).to eq(3)
    end

    context "with current seller" do
      let(:product) { create(:product) }
      let(:pundit_user) { SellerContext.new(user: buyer, seller: buyer) }

      it "includes wishlists" do
        wishlist = create(:wishlist, user: buyer)
        presenter = described_class.new(product:)

        expect(presenter.props(seller_custom_domain_url: nil, request:, pundit_user:)[:wishlists]).to eq([{ id: wishlist.external_id, name: wishlist.name, selections_in_wishlist: [] }])
      end
    end

    context "when custom domain is specified" do
      let(:product) { create(:product) }

      it "uses the custom domain for the seller profile url" do
        expect(
          presenter.props(seller_custom_domain_url: "https://example.com", request:, pundit_user: nil, recommended_by: "discover")[:product][:seller][:profile_url]
        ).to eq "https://example.com?recommended_by=discover"
      end
    end

    context "with public files" do
      let(:product) { create(:product) }
      let!(:public_file1) { create(:public_file, :with_audio, resource: product) }
      let!(:public_file2) { create(:public_file, resource: product) }
      let!(:public_file3) { create(:public_file, :with_audio, deleted_at: 1.day.ago) }

      before do
        Feature.activate_user(:audio_previews, product.user)

        public_file1.file.analyze
      end

      it "includes public files" do
        props = described_class.new(product:).props(seller_custom_domain_url: nil, request:, pundit_user: nil)[:product]

        expect(props[:public_files].sole).to eq(PublicFilePresenter.new(public_file: public_file1).props)
        expect(props[:audio_previews_enabled]).to be(true)
      end
    end
  end
end
