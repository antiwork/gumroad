# frozen_string_literal: true

require "spec_helper"

describe ProductPresenter do
  include Rails.application.routes.url_helpers
  include PreorderHelper
  include ProductsHelper

  describe ".new_page_props" do
    let(:new_seller) { create(:named_seller) }
    let(:existing_seller) { create(:user) }

    before do
      create(:product, user: existing_seller)
    end

    it "returns well-formed props with show_orientation_text true for new users with no products" do
      props = described_class.new_page_props(current_seller: new_seller)
      release_at_date = displayable_release_at_date(1.month.from_now, new_seller.timezone)

      expect(props).to match(
        {
          current_seller_currency_code: "usd",
          native_product_types: ["digital", "course", "ebook", "membership", "bundle"],
          service_product_types: ["call", "coffee"],
          release_at_date:,
          show_orientation_text: true,
          eligible_for_service_products: false,
          ai_generation_enabled: false,
          ai_promo_dismissed: false,
        }
      )
    end

    it "returns well-formed props with show_orientation_text false for existing users with products" do
      props = described_class.new_page_props(current_seller: existing_seller)
      release_at_date = displayable_release_at_date(1.month.from_now, existing_seller.timezone)

      expect(props).to match(
        {
          current_seller_currency_code: "usd",
          native_product_types: ["digital", "course", "ebook", "membership", "bundle"],
          service_product_types: ["call", "coffee"],
          release_at_date:,
          show_orientation_text: false,
          eligible_for_service_products: false,
          ai_generation_enabled: false,
          ai_promo_dismissed: false,
        }
      )
    end

    context "commissions are enabled" do
      before { Feature.activate_user(:commissions, existing_seller) }

      it "includes commission in the native product types" do
        expect(described_class.new_page_props(current_seller: existing_seller)[:service_product_types]).to include("commission")
      end
    end

    context "physical products are enabled" do
      before { existing_seller.update!(can_create_physical_products: true) }

      it "includes physical in the native product types" do
        expect(described_class.new_page_props(current_seller: existing_seller)[:native_product_types]).to include("physical")
      end
    end

    context "user is eligible for service products" do
      let(:existing_seller) { create(:user, :eligible_for_service_products) }

      it "sets eligible_for_service_products to true" do
        expect(described_class.new_page_props(current_seller: existing_seller)[:eligible_for_service_products]).to eq(true)
      end
    end
  end

  describe "#product_props" do
    let(:request) { instance_double(ActionDispatch::Request, host: "test.gumroad.com", host_with_port: "test.gumroad.com:31337", protocol: "http", cookie_jar: {}, remote_ip: "0.0.0.0") }
    let(:buyer) { create(:user) }
    let(:pundit_user) { SellerContext.new(user: buyer, seller: buyer) }
    let(:product) { create(:product) }
    let!(:purchase) { create(:purchase, link: product, purchaser: buyer) }

    it "returns properties from the page presenter" do
      expect(ProductPresenter::ProductProps).to receive(:new).with(product:).and_call_original

      expect(described_class.new(product:, request:, pundit_user:).product_props(recommended_by: "discover", seller_custom_domain_url: nil)).to eq(
        {
          product: {
            id: product.external_id,
            price_cents: 100,
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
            long_url: short_link_url(product.unique_permalink, host: product.user.subdomain_with_protocol),
            main_cover_id: nil,
            name: product.name,
            permalink: product.unique_permalink,
            preorder: nil,
            duration_in_months: nil,
            quantity_remaining: nil,
            ratings: {
              count: 0,
              average: 0,
              percentages: [0, 0, 0, 0, 0],
            },
            seller: {
              avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
              id: product.user.external_id,
              name: product.user.username,
              profile_url: product.user.profile_url(recommended_by: "discover"),
            },
            collaborating_user: nil,
            is_compliance_blocked: false,
            is_published: true,
            is_physical: false,
            attributes: [],
            free_trial: nil,
            is_quantity_enabled: false,
            is_multiseat_license: false,
            hide_sold_out_variants: false,
            native_type: "digital",
            is_stream_only: false,
            streamable: false,
            options: [],
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
              title: "30-day money back guarantee",
              fine_print: nil,
              updated_at: buyer.refund_policy.updated_at.to_date,
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
            review: nil,
            should_show_receipt: true,
            is_gift_receiver_purchase: false,
            show_view_content_button_on_product_page: false,
            subscription_has_lapsed: false,
            total_price_including_tax_and_shipping: "$1"
          },
          wishlists: [],
        }
      )
    end
  end

  describe "#product_page_props" do
    let(:request) { ActionDispatch::TestRequest.create }
    let(:pundit_user) { SellerContext.new(user: @user, seller: @user) }
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, main_section_index: 1) }
    let(:sections) { create_list(:seller_profile_products_section, 2, seller: seller, product:) }

    it "returns the properties for the product page" do
      product.update!(sections: sections.map(&:id).reverse)
      presenter = described_class.new(product:, request:, pundit_user:)
      sections_props = ProfileSectionsPresenter.new(seller:, query: product.seller_profile_sections).props(request:, pundit_user:, seller_custom_domain_url: nil)
      expect(ProfileSectionsPresenter).to receive(:new).with(seller:, query: product.seller_profile_sections).and_call_original

      expect(presenter.product_page_props(seller_custom_domain_url: nil)).to eq({
                                                                                  **presenter.product_props(seller_custom_domain_url: nil),
                                                                                  **sections_props,
                                                                                  sections: sections_props[:sections].reverse,
                                                                                  main_section_index: 1,
                                                                                })
    end
  end

  describe "#edit_props" do
    let(:request) { instance_double(ActionDispatch::Request, host: "test.gumroad.com", host_with_port: "test.gumroad.com:1234", protocol: "http") }
    let(:circle_integration) { create(:circle_integration) }
    let(:discord_integration) { create(:discord_integration) }
    let(:product) do
      create(
        :product_with_pdf_file,
        name: "Product",
        description: "I am a product!",
        custom_permalink: "custom",
        customizable_price: true,
        suggested_price_cents: 200,
        max_purchase_count: 50,
        quantity_enabled: true,
        should_show_sales_count: true,
        active_integrations: [
          circle_integration,
          discord_integration
        ],
        tag: "hi",
        taxonomy_id: 1,
        discover_fee_per_thousand: 300,
        is_adult: true,
        native_type: "ebook",
      )
    end
    let(:presenter) { described_class.new(product:, request:) }
    let!(:asset_previews) { create_list(:asset_preview, 2, link: product) }
    let!(:thumbnail) { create(:thumbnail, product:) }
    let!(:refund_policy) { create(:product_refund_policy, product:, seller: product.user) }
    let!(:other_refund_policy) { create(:product_refund_policy, product: create(:product, user: product.user, name: "Other product"), max_refund_period_in_days: 0, fine_print: "This is another refund policy") }
    let!(:variant_category) { create(:variant_category, link: product, title: "Version") }
    let!(:version1) { create(:variant, variant_category:, name: "Version 1", description: "I am version 1") }
    let!(:version2) { create(:variant, variant_category:, name: "Version 2", price_difference_cents: 100, max_purchase_count: 100) }
    let!(:profile_section) { create(:seller_profile_products_section, seller: product.user, shown_products: [product.id]) }
    let!(:custom_domain) { create(:custom_domain, :with_product, product:) }
    let(:product_files) do
      product_file = product.product_files.first
      [{ attached_product_name: "Product",  extension: "PDF", file_name: "Display Name", display_name: "Display Name", description: "Description", file_size: 50, id: product_file.external_id, is_pdf: true, pdf_stamp_enabled: false, is_streamable: false, stream_only: false, is_transcoding_in_progress: false, pagelength: 3, duration: nil, subtitle_files: [], url: product_file.url, thumbnail: nil, status: { type: "saved" } }]
    end
    let(:available_countries) { ShippingDestination::Destinations.shipping_countries.map { { code: _1[0], name: _1[1] } } }

    before do
      product.save_custom_button_text_option("pay_prompt")
      product.save_custom_summary("To summarize, I am a product.")
      product.save_custom_attributes({ "Detail 1" => "Value 1" })
      product.user.reload
    end

    it "returns the properties for the product edit page" do
      expect(presenter.edit_props).to eq(
        {
          product: {
            name: "Product",
            description: "I am a product!",
            custom_permalink: "custom",
            price_cents: 100,
            **ProductPresenter::InstallmentPlanProps.new(product: presenter.product).props,
            customizable_price: true,
            suggested_price_cents: 200,
            custom_button_text_option: "pay_prompt",
            custom_summary: "To summarize, I am a product.",
            custom_attributes: { "Detail 1" => "Value 1" },
            file_attributes: [
              {
                name: "Size",
                value: "50 Bytes"
              },
              {
                name: "Length",
                value: "3 pages"
              }
            ],
            max_purchase_count: 50,
            quantity_enabled: true,
            can_enable_quantity: true,
            should_show_sales_count: true,
            hide_sold_out_variants: false,
            is_epublication: false,
            product_refund_policy_enabled: false,
            section_ids: [profile_section.external_id],
            taxonomy_id: "1",
            tags: ["hi"],
            display_product_reviews: true,
            is_adult: true,
            discover_fee_per_thousand: 300,
            refund_policy: {
              allowed_refund_periods_in_days: [
                {
                  key: 0,
                  value: "No refunds allowed"
                },
                {
                  key: 7,
                  value: "7-day money back guarantee"
                },
                {
                  key: 14,
                  value: "14-day money back guarantee"
                },
                {
                  key: 30,
                  value: "30-day money back guarantee"
                },
                {
                  key: 183,
                  value: "6-month money back guarantee"
                }
              ],
              max_refund_period_in_days: 30,
              title: "30-day money back guarantee",
              fine_print: "This is a product-level refund policy",
              fine_print_enabled: true
            },
            is_published: true,
            covers: asset_previews.map(&:as_json),
            integrations: {
              "circle" => circle_integration.as_json,
              "discord" => discord_integration.as_json,
              "zoom" => nil,
              "google_calendar" => nil,
            },
            variants: [
              {
                id: version1.external_id,
                name: "Version 1",
                description: "I am version 1",
                price_difference_cents: 0,
                max_purchase_count: nil,
                integrations: {
                  "circle" => false,
                  "discord" => false,
                  "zoom" => false,
                  "google_calendar" => false,
                },
                rich_content: [],
                sales_count_for_inventory: 0,
                active_subscribers_count: 0,
              },
              {
                id: version2.external_id,
                name: "Version 2",
                description: "",
                price_difference_cents: 100,
                max_purchase_count: 100,
                integrations: {
                  "circle" => false,
                  "discord" => false,
                  "zoom" => false,
                  "google_calendar" => false,
                },
                rich_content: [],
                sales_count_for_inventory: 0,
                active_subscribers_count: 0,
              }
            ],
            availabilities: [],
            shipping_destinations: [],
            custom_domain: custom_domain.domain,
            free_trial_enabled: false,
            free_trial_duration_amount: nil,
            free_trial_duration_unit: nil,
            should_include_last_post: false,
            should_show_all_posts: false,
            block_access_after_membership_cancellation: false,
            duration_in_months: nil,
            subscription_duration: nil,
            collaborating_user: nil,
            rich_content: [],
            files: product_files,
            has_same_rich_content_for_all_variants: false,
            is_multiseat_license: false,
            call_limitation_info: nil,
            native_type: "ebook",
            require_shipping: false,
            cancellation_discount: nil,
            public_files: [],
            audio_previews_enabled: false,
            community_chat_enabled: nil,
          },
          id: product.external_id,
          unique_permalink: product.unique_permalink,
          currency_type: "usd",
          thumbnail: thumbnail.as_json,
          refund_policies: [
            {
              id: other_refund_policy.external_id,
              title: "No refunds allowed",
              fine_print: "This is another refund policy",
              product_name: "Other product",
              max_refund_period_in_days: 0,
            }
          ],
          is_tiered_membership: false,
          is_listed_on_discover: false,
          is_physical: false,
          earliest_membership_price_change_date: BaseVariant::MINIMUM_DAYS_TIL_EXISTING_MEMBERSHIP_PRICE_CHANGE.days.from_now.in_time_zone(product.user.timezone).iso8601,
          profile_sections: [
            {
              id: profile_section.external_id,
              header: "",
              product_names: ["Product"],
              default: true,
            }
          ],
          taxonomies: Discover::TaxonomyPresenter.new.taxonomies_for_nav,
          custom_domain_verification_status: {
            success: false,
            message: "Domain verification failed. Please make sure you have correctly configured the DNS record for #{custom_domain.domain}."
          },
          sales_count_for_inventory: 0,
          successful_sales_count: 0,
          ratings: {
            count: 0,
            average: 0,
            percentages: [0, 0, 0, 0, 0],
          },
          seller: UserPresenter.new(user: product.user).author_byline_props,
          existing_files: product_files,
          s3_url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}",
          aws_key: AWS_ACCESS_KEY,
          available_countries:,
          google_client_id: "524830719781-6h0t2d14kpj9j76utctvs3udl0embkpi.apps.googleusercontent.com",
          google_calendar_enabled: false,
          seller_refund_policy_enabled: true,
          seller_refund_policy: {
            title: "30-day money back guarantee",
            fine_print: nil,
          },
          cancellation_discounts_enabled: false,
        }
      )
    end

    context "membership" do
      let(:membership) do
        create(
          :membership_product,
          name: "Membership",
          native_type: "membership",
          description: "Join now",
          active_integrations: [discord_integration],
          free_trial_enabled: true,
          free_trial_duration_amount: 1,
          free_trial_duration_unit: "month",
          duration_in_months: 6,
          should_include_last_post: true,
          should_show_all_posts: true,
        )
      end
      let(:presenter) { described_class.new(product: membership, request:) }
      let(:tier) { membership.alive_variants.first }
      let!(:collaborator) { create(:collaborator, seller: membership.user, products: [membership]) }
      let!(:cancellation_discount_offer_code) { create(:cancellation_discount_offer_code, user: membership.user, amount_cents: 0, products: [membership]) }

      before do
        tier.update!(
          description: "I am a tier!",
          max_purchase_count: 10,
          customizable_price: true,
          apply_price_changes_to_existing_memberships: true,
          subscription_price_change_effective_date: 10.days.from_now,
          subscription_price_change_message: "Price change!",
        )
        tier.prices.first.update!(suggested_price_cents: 200)
        tier.active_integrations << discord_integration
        create(:purchase, :with_review, link: membership, variant_attributes: [tier])
        membership.save_custom_button_text_option("")
        Feature.activate_user(:cancellation_discounts, membership.user)
      end

      it "returns the properties for the product edit page" do
        expect(presenter.edit_props).to eq(
          {
            product: {
              name: "Membership",
              description: "Join now",
              custom_permalink: nil,
              price_cents: 0,
              **ProductPresenter::InstallmentPlanProps.new(product: presenter.product).props,
              customizable_price: false,
              suggested_price_cents: nil,
              custom_button_text_option: nil,
              custom_summary: nil,
              custom_attributes: [],
              file_attributes: [],
              max_purchase_count: nil,
              quantity_enabled: false,
              can_enable_quantity: false,
              should_show_sales_count: false,
              hide_sold_out_variants: false,
              is_epublication: false,
              product_refund_policy_enabled: false,
              refund_policy: {
                allowed_refund_periods_in_days: [
                  {
                    key: 0,
                    value: "No refunds allowed"
                  },
                  {
                    key: 7,
                    value: "7-day money back guarantee"
                  },
                  {
                    key: 14,
                    value: "14-day money back guarantee"
                  },
                  {
                    key: 30,
                    value: "30-day money back guarantee"
                  },
                  {
                    key: 183,
                    value: "6-month money back guarantee"
                  }
                ],
                max_refund_period_in_days: 30,
                title: "30-day money back guarantee",
                fine_print: nil,
                fine_print_enabled: false,
              },
              is_published: true,
              covers: [],
              integrations: {
                "circle" => nil,
                "discord" => discord_integration.as_json,
                "zoom" => nil,
                "google_calendar" => nil,
              },
              variants: [
                {
                  id: tier.external_id,
                  name: "Untitled",
                  description: "I am a tier!",
                  max_purchase_count: 10,
                  customizable_price: true,
                  recurrence_price_values: {
                    "monthly" => {
                      enabled: true,
                      price_cents: 100,
                      price: "1",
                      suggested_price_cents: 200,
                      suggested_price: "2",
                    },
                    "quarterly" => { enabled: false },
                    "biannually" => { enabled: false },
                    "yearly" => { enabled: false },
                    "every_two_years" => { enabled: false },
                  },
                  integrations: {
                    "circle" => false,
                    "discord" => true,
                    "zoom" => false,
                    "google_calendar" => false,
                  },
                  apply_price_changes_to_existing_memberships: true,
                  subscription_price_change_effective_date: tier.subscription_price_change_effective_date,
                  subscription_price_change_message: "Price change!",
                  rich_content: [],
                  sales_count_for_inventory: 1,
                  active_subscribers_count: 0,
                },
              ],
              availabilities: [],
              shipping_destinations: [],
              section_ids: [],
              taxonomy_id: nil,
              tags: [],
              display_product_reviews: true,
              is_adult: false,
              discover_fee_per_thousand: 100,
              custom_domain: "",
              free_trial_enabled: true,
              free_trial_duration_amount: 1,
              free_trial_duration_unit: "month",
              should_include_last_post: true,
              should_show_all_posts: true,
              block_access_after_membership_cancellation: false,
              duration_in_months: 6,
              subscription_duration: "monthly",
              collaborating_user: {
                id: collaborator.affiliate_user.external_id,
                name: collaborator.affiliate_user.username,
                profile_url: collaborator.affiliate_user.subdomain_with_protocol,
                avatar_url: collaborator.affiliate_user.avatar_url,
              },
              rich_content: [],
              files: [],
              has_same_rich_content_for_all_variants: false,
              is_multiseat_license: false,
              call_limitation_info: nil,
              native_type: "membership",
              require_shipping: false,
              cancellation_discount: {
                discount: {
                  type: "fixed",
                  cents: 0
                },
                duration_in_billing_cycles: 3
              },
              public_files: [],
              audio_previews_enabled: false,
              community_chat_enabled: nil,
            },
            id: membership.external_id,
            unique_permalink: membership.unique_permalink,
            currency_type: "usd",
            thumbnail: nil,
            refund_policies: [],
            is_tiered_membership: true,
            is_listed_on_discover: false,
            is_physical: false,
            earliest_membership_price_change_date: BaseVariant::MINIMUM_DAYS_TIL_EXISTING_MEMBERSHIP_PRICE_CHANGE.days.from_now.in_time_zone(membership.user.timezone).iso8601,
            profile_sections: [],
            taxonomies: Discover::TaxonomyPresenter.new.taxonomies_for_nav,
            custom_domain_verification_status: nil,
            sales_count_for_inventory: 0,
            successful_sales_count: 0,
            ratings: {
              count: 1,
              average: 5,
              percentages: [0, 0, 0, 0, 100],
            },
            seller: UserPresenter.new(user: membership.user).author_byline_props,
            existing_files: [],
            s3_url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}",
            aws_key: AWS_ACCESS_KEY,
            available_countries:,
            google_client_id: "524830719781-6h0t2d14kpj9j76utctvs3udl0embkpi.apps.googleusercontent.com",
            google_calendar_enabled: false,
            seller_refund_policy_enabled: true,
            seller_refund_policy: {
              title: "30-day money back guarantee",
              fine_print: nil,
            },
            cancellation_discounts_enabled: true,
          }
        )
      end
    end

    context "call product" do
      let(:call) { create(:call_product, durations: []) }
      let(:presenter) { described_class.new(product: call, request:) }
      let(:durations) { call.variant_categories.first }
      let!(:thirty_minutes) { create(:variant, variant_category: durations, name: "30 minutes", duration_in_minutes: 30, description: "Shorter call") }
      let!(:sixty_minutes) { create(:variant, variant_category: durations, name: "60 minutes", duration_in_minutes: 60, description: "Longer call") }
      let!(:availability) { create(:call_availability, call:) }

      before do
        call.call_limitation_info.update!(minimum_notice_in_minutes: 30, maximum_calls_per_day: 5)
      end

      it "returns properties for the product edit page" do
        product_props = presenter.edit_props[:product]
        expect(product_props[:can_enable_quantity]).to eq(false)
        expect(product_props[:variants]).to eq(
          [
            {
              id: thirty_minutes.external_id,
              name: "30 minutes",
              description: "Shorter call",
              price_difference_cents: 0,
              duration_in_minutes: 30,
              max_purchase_count: nil,
              integrations: {
                "circle" => false,
                "discord" => false,
                "zoom" => false,
                "google_calendar" => false,
              },
              rich_content: [],
              sales_count_for_inventory: 0,
              active_subscribers_count: 0,
            },
            {
              id: sixty_minutes.external_id,
              name: "60 minutes",
              description: "Longer call",
              price_difference_cents: 0,
              duration_in_minutes: 60,
              max_purchase_count: nil,
              integrations: {
                "circle" => false,
                "discord" => false,
                "zoom" => false,
                "google_calendar" => false,
              },
              rich_content: [],
              sales_count_for_inventory: 0,
              active_subscribers_count: 0,
            },
          ]
        )
        expect(product_props[:call_limitation_info]).to eq(
          {
            minimum_notice_in_minutes: 30,
            maximum_calls_per_day: 5,
          }
        )
      end

      it "returns availabilities" do
        expect(presenter.edit_props[:product][:availabilities]).to eq(
          [
            {
              id: availability.external_id,
              start_time: availability.start_time.iso8601,
              end_time: availability.end_time.iso8601,
            }
          ]
        )
      end
    end

    context "new product" do
      let(:new_product) { create(:product, name: "Product", description: "Boring") }
      let(:presenter) { described_class.new(product: new_product, request:) }

      it "returns the properties for the product edit page" do
        expect(presenter.edit_props).to eq(
          {
            product: {
              name: "Product",
              description: "Boring",
              custom_permalink: nil,
              price_cents: 100,
              **ProductPresenter::InstallmentPlanProps.new(product: presenter.product).props,
              customizable_price: false,
              suggested_price_cents: nil,
              custom_button_text_option: nil,
              custom_summary: nil,
              custom_attributes: [],
              file_attributes: [],
              max_purchase_count: nil,
              quantity_enabled: false,
              can_enable_quantity: true,
              should_show_sales_count: false,
              hide_sold_out_variants: false,
              is_epublication: false,
              product_refund_policy_enabled: false,
              section_ids: [],
              taxonomy_id: nil,
              tags: [],
              display_product_reviews: true,
              is_adult: false,
              discover_fee_per_thousand: 100,
              refund_policy: {
                allowed_refund_periods_in_days: [
                  {
                    key: 0,
                    value: "No refunds allowed"
                  },
                  {
                    key: 7,
                    value: "7-day money back guarantee"
                  },
                  {
                    key: 14,
                    value: "14-day money back guarantee"
                  },
                  {
                    key: 30,
                    value: "30-day money back guarantee"
                  },
                  {
                    key: 183,
                    value: "6-month money back guarantee"
                  }
                ],
                max_refund_period_in_days: 30,
                title: "30-day money back guarantee",
                fine_print: nil,
                fine_print_enabled: false,
              },
              is_published: true,
              covers: [],
              integrations: {
                "circle" => nil,
                "discord" => nil,
                "zoom" => nil,
                "google_calendar" => nil,
              },
              variants: [],
              availabilities: [],
              shipping_destinations: [],
              custom_domain: "",
              free_trial_enabled: false,
              free_trial_duration_amount: nil,
              free_trial_duration_unit: nil,
              should_include_last_post: false,
              should_show_all_posts: false,
              block_access_after_membership_cancellation: false,
              duration_in_months: nil,
              subscription_duration: nil,
              collaborating_user: nil,
              rich_content: [],
              files: [],
              has_same_rich_content_for_all_variants: false,
              is_multiseat_license: false,
              call_limitation_info: nil,
              native_type: "digital",
              require_shipping: false,
              cancellation_discount: nil,
              public_files: [],
              audio_previews_enabled: false,
              community_chat_enabled: nil,
            },
            id: new_product.external_id,
            unique_permalink: new_product.unique_permalink,
            currency_type: "usd",
            thumbnail: nil,
            refund_policies: [],
            is_tiered_membership: false,
            is_listed_on_discover: false,
            is_physical: false,
            earliest_membership_price_change_date: BaseVariant::MINIMUM_DAYS_TIL_EXISTING_MEMBERSHIP_PRICE_CHANGE.days.from_now.in_time_zone(new_product.user.timezone).iso8601,
            profile_sections: [],
            taxonomies: Discover::TaxonomyPresenter.new.taxonomies_for_nav,
            custom_domain_verification_status: nil,
            sales_count_for_inventory: 0,
            successful_sales_count: 0,
            ratings: {
              count: 0,
              average: 0,
              percentages: [0, 0, 0, 0, 0],
            },
            seller: UserPresenter.new(user: new_product.user).author_byline_props,
            existing_files: [],
            s3_url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}",
            aws_key: AWS_ACCESS_KEY,
            available_countries:,
            google_client_id: "524830719781-6h0t2d14kpj9j76utctvs3udl0embkpi.apps.googleusercontent.com",
            google_calendar_enabled: false,
            seller_refund_policy_enabled: true,
            seller_refund_policy: {
              title: "30-day money back guarantee",
              fine_print: nil,
            },
            cancellation_discounts_enabled: false,
          }
        )
      end
    end

    context "with public files" do
      let!(:public_file1) { create(:public_file, :with_audio, resource: product) }
      let!(:public_file2) { create(:public_file, resource: product) }
      let!(:public_file3) { create(:public_file, :with_audio, deleted_at: 1.day.ago) }

      before do
        Feature.activate_user(:audio_previews, product.user)

        public_file1.file.analyze
      end

      it "includes public files" do
        props = described_class.new(product:).edit_props[:product]

        expect(props[:public_files].sole).to eq(PublicFilePresenter.new(public_file: public_file1).props)
        expect(props[:audio_previews_enabled]).to be(true)
      end
    end

    context "with community chat enabled" do
      before do
        Feature.activate_user(:communities, product.user)
        create(:community, seller: product.user, resource: product)
        product.update!(community_chat_enabled: true)
      end

      it "includes community chat enabled" do
        expect(described_class.new(product:).edit_props[:product][:community_chat_enabled]).to be(true)
      end

      context "when the community is disabled" do
        before do
          product.update!(community_chat_enabled: false)
        end

        it "includes community chat disabled" do
          expect(described_class.new(product:).edit_props[:product][:community_chat_enabled]).to be(false)
        end
      end
    end
  end

  describe ".card_for_web" do
    let(:request) { instance_double(ActionDispatch::Request, host: "test.gumroad.com", host_with_port: "test.gumroad.com:1234", protocol: "http") }
    let(:product) { create(:product) }

    it "returns properties from the card presenter" do
      expect(described_class.card_for_web(product:, request:, recommended_by: "discover")).to eq(ProductPresenter::Card.new(product:).for_web(request:, recommended_by: "discover"))
    end

    it "passes compute_description parameter to the card presenter" do
      expect(ProductPresenter::Card).to receive(:new).with(product:).and_call_original
      expect_any_instance_of(ProductPresenter::Card).to receive(:for_web).with(request:, recommended_by: "discover", recommender_model_name: nil, target: nil, show_seller: true, affiliate_id: nil, query: nil, compute_description: false)

      described_class.card_for_web(product:, request:, recommended_by: "discover", compute_description: false)
    end

    it "defaults compute_description to true when not provided" do
      expect(ProductPresenter::Card).to receive(:new).with(product:).and_call_original
      expect_any_instance_of(ProductPresenter::Card).to receive(:for_web).with(request:, recommended_by: "discover", recommender_model_name: nil, target: nil, show_seller: true, affiliate_id: nil, query: nil, compute_description: true)

      described_class.card_for_web(product:, request:, recommended_by: "discover")
    end
  end

  describe ".card_for_email" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }

    it "returns properties from the card presenter" do
      expect(ProductPresenter::Card).to receive(:new).with(product:).and_call_original

      expect(described_class.card_for_email(product:)).to eq(
        {
          name: product.name,
          thumbnail_url: ActionController::Base.helpers.asset_url("native_types/thumbnails/digital.png"),
          url: short_link_url(product.general_permalink, host: "http://#{seller.username}.test.gumroad.com:31337"),
          seller: {
            name: seller.name,
            profile_url: seller.profile_url,
            avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
          },
        }
      )
    end
  end

  describe "#admin_info" do
    before do
      @product = create(:product_with_pdf_file, name: "Sample Product", description: "Simple description", user: create(:named_user))
      @instance = described_class.new(product: @product)
    end

    it "returns product data object for the admin page" do
      expect(@instance.admin_info).to eq(
        preorder: nil,
        has_stream_only_files: false,
        is_recurring_billing: false,
        should_show_sales_count: false,
        price_cents: 100,
        sales_count: 0,
        custom_summary: nil,
        file_info_attributes: [
          { name: "Size", value: "50 Bytes" },
          { name: "Length", value: "3 pages" }
        ],
        custom_attributes: [],
                                               )
    end

    context "empty custom attributes" do
      before do
        @product.save_custom_attributes([
                                          { "name": "name", "value": "value" },
                                          { "name": "empty-value", "value": "" },
                                          { "name": "", "value": "empty-name" },
                                          { "name": " ", "value": " " }
                                        ])
      end

      it "excludes fully empty custom attributes" do
        expect(@instance.admin_info[:custom_attributes]).to eq([
                                                                 { name: "name", value: "value" },
                                                                 { name: "empty-value", value: "" },
                                                                 { name: "", value: "empty-name" }
                                                               ])
      end
    end

    context "a membership product" do
      before do
        @product = create(:membership_product_with_preset_tiered_pricing, :with_free_trial_enabled, name: "Sample Product", description: "https://gumroad.com", user: create(:named_user))
        @instance = described_class.new(product: @product)
      end

      it "sets is_recurring_billing correctly" do
        expect(@instance.admin_info[:is_recurring_billing]).to eq true
      end
    end

    it "hides sales count" do
      @product.update(should_show_sales_count: false)
      allow(@instance.product).to receive(:successful_sales_count).and_return(3)
      expect(@instance.admin_info[:sales_count]).to eq(0)
    end
  end

  describe "#existing_files" do
    let(:seller) { create(:user) }
    let(:product) { create(:product_with_pdf_file, user: seller) }
    let(:presenter) { described_class.new(product: product) }
    let(:product_files) do
      product_file = product.product_files.first
      [{ attached_product_name: product.name,  extension: "PDF", file_name: "Display Name", display_name: "Display Name", description: "Description", file_size: 50, id: product_file.external_id, is_pdf: true, pdf_stamp_enabled: false, is_streamable: false, stream_only: false, is_transcoding_in_progress: false, pagelength: 3, duration: nil, subtitle_files: [], url: product_file.url, thumbnail: nil, status: { type: "saved" } }]
    end

    it "returns existing files" do
      expect(presenter.existing_files).to eq(product_files)
    end
  end
end
