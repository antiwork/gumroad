# frozen_string_literal: true

describe InstallmentPresenter do
  let(:seller) { create(:named_seller) }

  describe "#new_page_props" do
    let!(:product1) { create(:product_with_digital_versions, name: "Product 1", user: seller) }
    let!(:product2) { create(:product, name: "Product 2", user: seller, archived: true) }
    let!(:membership) { create(:membership_product, name: "Membership product", user: seller) }
    let!(:physical_product) { create(:physical_product, name: "Physical product", user: seller, skus_enabled: true) }
    let!(:sku1) { create(:sku, link: physical_product, name: "Blue - Large") }
    let!(:sku2) { create(:sku, link: physical_product, name: "Green - Small") }
    let!(:installment) { create(:installment, seller:, allow_comments: true) }

    it "returns the correct display_type" do
      expect(described_class.new(seller:, installment:).props[:display_type]).to eq("draft")
    end

    it "returns necessary props" do
      section = create(:seller_profile_posts_section, seller:)

      props = described_class.new(seller:).new_page_props

      expect(props.keys).to include(:context)
      expect(props[:context].keys).to match_array(%i(audience_types products affiliate_products timezone currency_type countries profile_sections has_scheduled_emails aws_access_key_id s3_url user_id allow_comments_by_default from_tab))
      expect(props[:context][:products]).to match_array(
        [
          {
            permalink: product1.unique_permalink,
            name: "Product 1",
            archived: false,
            variants: [
              {
                id: product1.variants.first.external_id,
                name: "Untitled 1"
              },
              {
                id: product1.variants.second.external_id,
                name: "Untitled 2"
              }
            ]
          },
          {
            permalink: membership.unique_permalink,
            name: "Membership product",
            archived: false,
            variants: [
              {
                id: membership.tiers.sole.external_id,
                name: "Untitled"
              }
            ]
          },
          {
            permalink: physical_product.unique_permalink,
            name: "Physical product",
            archived: false,
            variants: [
              {
                id: sku1.external_id,
                name: "Blue - Large"
              }, {
                id: sku2.external_id,
                name: "Green - Small"
              }
            ]
          }
        ]
      )
      expect(props[:context][:affiliate_products]).to match_array(
        [
          {
            permalink: product1.unique_permalink,
            name: "Product 1",
            archived: false
          },
          {
            permalink: membership.unique_permalink,
            name: "Membership product",
            archived: false
          },
          {
            permalink: physical_product.unique_permalink,
            name: "Physical product",
            archived: false
          }
        ]
      )
      expect(props[:context][:timezone]).to eq(ActiveSupport::TimeZone[seller.timezone].now.strftime("%Z"))
      expect(props[:context][:currency_type]).to eq("usd")
      expect(props[:context][:countries]).to match_array(["United States"] + Compliance::Countries.for_select.map { _1.last }.without("United States"))
      expect(props[:context][:profile_sections]).to eq([{ id: section.external_id, name: nil }])
      expect(props[:context][:has_scheduled_emails]).to be(false)
      expect(props[:context][:user_id]).to eq(seller.external_id)
      expect(props[:context][:allow_comments_by_default]).to be(true)
    end

    it "returns true 'has_scheduled_emails' when seller has scheduled emails" do
      create(:installment, seller:, ready_to_publish: true)
      expect(described_class.new(seller:).new_page_props[:context][:has_scheduled_emails]).to be(true)
    end

    it "returns necessary props with `installment` attribute when `copy_from` is present" do
      reference_installment = create(:product_installment, seller:, link: product1)
      props = described_class.new(seller:).new_page_props(copy_from: reference_installment.external_id)
      expect(props.keys).to match_array(%i(context installment))
      expect(props[:installment]).to eq(described_class.new(seller:, installment: reference_installment).props.except(:external_id))
    end
  end

  describe "#edit_page_props" do
    let!(:product) { create(:product_with_digital_versions, name: "Product 1", user: seller) }
    let!(:installment) { create(:installment, seller:, link: product, allow_comments: false) }

    it "returns necessary props" do
      props = described_class.new(seller:, installment:).edit_page_props

      expect(props.keys).to match_array(%i(context installment))
      expect(props[:context].keys).to match_array(%i(audience_types products affiliate_products timezone currency_type countries profile_sections has_scheduled_emails aws_access_key_id s3_url user_id allow_comments_by_default from_tab))
      expect(props[:context][:products]).to match_array(
        [
          {
            permalink: product.unique_permalink,
            name: "Product 1",
            archived: false,
            variants: [
              {
                id: product.variants.first.external_id,
                name: "Untitled 1"
              },
              {
                id: product.variants.second.external_id,
                name: "Untitled 2"
              }
            ]
          }
        ]
      )
      expect(props[:context][:affiliate_products]).to match_array(
        [
          {
            permalink: product.unique_permalink,
            name: "Product 1",
            archived: false
          }
        ]
      )
      expect(props[:context][:timezone]).to eq(ActiveSupport::TimeZone[seller.timezone].now.strftime("%Z"))
      expect(props[:context][:currency_type]).to eq("usd")
      expect(props[:context][:countries]).to match_array(["United States"] + Compliance::Countries.for_select.map { _1.last }.without("United States"))
      expect(props[:context][:profile_sections]).to eq([])
      expect(props[:context][:has_scheduled_emails]).to be(false)
      expect(props[:context][:user_id]).to eq(seller.external_id)
      expect(props[:context][:allow_comments_by_default]).to be(false)
      expect(props[:installment]).to eq(described_class.new(seller:, installment:).props)
    end
  end

  describe "#props" do
    let(:product) { create(:product, user: seller) }

    let(:installment) { create(:installment, link: product, published_at: 1.day.ago, name: "1 day") }

    before do
      create(:installment_rule, installment:, delayed_delivery_time: 1.day)
    end

    it "includes the necessary installment details" do
      section = create(:seller_profile_posts_section, seller:, shown_posts: [installment.id])
      create(:seller_profile_posts_section, seller:, shown_posts: [create(:installment).id])
      installment.update!(shown_on_profile: true)

      props = described_class.new(seller:, installment:).props

      expect(props).to match(a_hash_including(
        name: "1 day",
        message: installment.message,
        files: [],
        published_at: installment.published_at,
        updated_at: installment.updated_at,
        external_id: installment.external_id,
        stream_only: false,
        call_to_action_text: nil,
        call_to_action_url: nil,
        streamable: false,
        sent_count: nil,
        click_count: 0,
        open_count: 0,
        click_rate: nil,
        open_rate: nil,
        clicked_urls: [],
        view_count: 0,
        full_url: installment.full_url,
        send_emails: true,
        shown_on_profile: true,
        has_been_blasted: false,
        shown_in_profile_sections: [section.external_id]
      ))
      expect(props.keys).to_not include(:published_once_already, :member_cancellation, :new_customers_only, :delayed_delivery_time_duration, :delayed_delivery_time_period, :displayed_delayed_delivery_time_period)
      expect(props.keys).to_not include(:recipient_description, :to_be_published_at)
    end

    context "when installment is of type `product`" do
      let!(:installment) { create(:product_installment, seller:, link: product, paid_more_than_cents: 100, paid_less_than_cents: 200, bought_from: "Japan", created_before: "2024-05-30", created_after: "2024-01-01", allow_comments: false) }

      it "includes necessary attributes" do
        props = described_class.new(seller:, installment:).props
        expect(props).to match(a_hash_including(
          external_id: installment.external_id,
          installment_type: "product",
          unique_permalink: product.unique_permalink,
          paid_more_than_cents: 100,
          paid_less_than_cents: 200,
          bought_from: "Japan",
          created_after: Date.parse("2024-01-01"),
          created_before: Date.parse("2024-05-30"),
          allow_comments: false,
        ))
      end
    end

    context "when installment is of type `variant`" do
      let(:variant) { create(:variant, variant_category: create(:variant_category, link: product)) }
      let!(:installment) { create(:variant_installment, seller:, base_variant: variant) }

      it "includes necessary attributes" do
        props = described_class.new(seller:, installment:).props
        expect(props).to match(a_hash_including(
          installment_type: "variant",
          variant_external_id: variant.external_id
        ))
      end
    end

    context "when installment is of type `seller`" do
      let(:variant) { create(:variant, variant_category: create(:variant_category, link: product)) }
      let(:product2) { create(:product, user: seller) }
      let!(:installment) { create(:seller_installment, seller:, bought_products: [product.unique_permalink], bought_variants: [variant.external_id], not_bought_products: [product2.unique_permalink]) }

      it "includes necessary attributes" do
        props = described_class.new(seller:, installment:).props
        expect(props).to match(a_hash_including(
          installment_type: "seller",
          bought_products: [product.unique_permalink],
          bought_variants: [variant.external_id],
          not_bought_products: [product2.unique_permalink]
        ))
      end
    end

    context "when installment is of type `follower`" do
      let!(:installment) { create(:follower_installment, seller:) }

      it "includes necessary attributes" do
        expect(described_class.new(seller:, installment:).props[:installment_type]).to eq("follower")
      end
    end

    context "when installment is of type `audience`" do
      let!(:installment) { create(:audience_installment, seller:) }

      it "includes necessary attributes" do
        expect(described_class.new(seller:, installment:).props[:installment_type]).to eq("audience")
      end
    end

    context "when installment is of type `affiliate`" do
      let!(:installment) { create(:affiliate_installment, seller:, affiliate_products: [product.unique_permalink]) }

      it "includes necessary attributes" do
        expect(described_class.new(seller:, installment:).props).to match(a_hash_including(
          installment_type: "affiliate",
          affiliate_products: [product.unique_permalink]
        ))
      end
    end

    context "when installment is not published" do
      before do
        installment.update!(published_at: nil)
      end

      it "includes appropriate 'recipient_description' for a seller type installment" do
        installment.update!(installment_type: Installment::SELLER_TYPE)

        props = described_class.new(seller:, installment:).props

        expect(props[:recipient_description]).to eq("Your customers")
      end

      it "includes appropriate 'recipient_description' for a product type installment" do
        installment.update!(installment_type: Installment::PRODUCT_TYPE)

        props = described_class.new(seller:, installment:).props

        expect(props[:recipient_description]).to eq("Customers of #{product.name}")
      end

      it "includes appropriate 'recipient_description' for a variant type installment" do
        variant = create(:variant)
        installment.update!(installment_type: Installment::VARIANT_TYPE, base_variant: variant)

        props = described_class.new(seller:, installment:).props

        expect(props[:recipient_description]).to eq("Customers of #{product.name} - #{variant.name}")
      end

      it "includes appropriate 'recipient_description' for a follower type installment" do
        installment.update!(installment_type: Installment::FOLLOWER_TYPE)

        props = described_class.new(seller:, installment:).props

        expect(props[:recipient_description]).to eq("Your followers")
      end

      it "includes appropriate 'recipient_description' for an audience type installment" do
        installment.update!(installment_type: Installment::AUDIENCE_TYPE)

        props = described_class.new(seller:, installment:).props

        expect(props[:recipient_description]).to eq("Your customers and followers")
      end

      it "includes appropriate 'recipient_description' for an affiliate type installment" do
        installment.update!(installment_type: Installment::AFFILIATE_TYPE)

        props = described_class.new(seller:, installment:).props

        expect(props[:recipient_description]).to eq("Your affiliates")
      end

      it "includes appropriate 'recipient_description' for an affiliate product post" do
        installment.update!(installment_type: Installment::AFFILIATE_TYPE, affiliate_products: [product.unique_permalink])

        props = described_class.new(seller:, installment:).props

        expect(props[:recipient_description]).to eq("Affiliates of #{product.name}")
      end

      context "when installment is scheduled" do
        it "includes 'to_be_published_at'" do
          installment.update!(ready_to_publish: true)
          props = described_class.new(seller:, installment:).props

          expect(props[:to_be_published_at]).to eq(installment.installment_rule.to_be_published_at)
        end
      end

      context "when installment is in draft" do
        it "does not include 'to_be_published_at'" do
          props = described_class.new(seller:, installment:).props

          expect(props).to_not have_key(:to_be_published_at)
        end
      end
    end

    context "for a workflow installment" do
      let(:workflow) { create(:workflow, seller:, link: product) }

      before do
        installment.update!(workflow:)
      end

      it "includes additional workflow-related details" do
        props = described_class.new(seller:, installment:).props

        expect(props).to match(a_hash_including(
          published_once_already: true,
          member_cancellation: false,
          new_customers_only: false,
          delayed_delivery_time_duration: 24,
          delayed_delivery_time_period: "hour",
          displayed_delayed_delivery_time_period: "Hours"
        ))
        expect(props.keys).to_not include(:clicked_urls, :view_count, :full_url, :recipient_description, :to_be_published_at)
      end
    end
  end
end
