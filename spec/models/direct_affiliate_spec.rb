# frozen_string_literal: true

require "spec_helper"

describe DirectAffiliate do
  let(:product) { create(:product, price_cents: 10_00, unique_permalink: "p") }
  let(:seller) { product.user }
  let(:affiliate_user) { create(:affiliate_user) }
  let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1000, products: [product]) }

  describe "associations" do
    it { is_expected.to belong_to(:seller).class_name("User") }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:affiliate_basis_points) }

    describe "eligible_for_stripe_payments" do
      let(:seller) { create(:user) }
      let(:affiliate_user) { create(:user) }
      let(:direct_affiliate) { build(:direct_affiliate, seller:, affiliate_user:) }

      context "when affiliate user has a Brazilian Stripe Connect account" do
        before do
          allow(affiliate_user).to receive(:has_brazilian_stripe_connect_account?).and_return(true)
          allow(seller).to receive(:has_brazilian_stripe_connect_account?).and_return(false)
        end

        it "is invalid" do
          expect(direct_affiliate).not_to be_valid
          expect(direct_affiliate.errors[:base]).to include(
            "This user cannot be added as an affiliate because they use a Brazilian Stripe account."
          )
        end
      end

      context "when seller has a Brazilian Stripe Connect account" do
        before do
          allow(affiliate_user).to receive(:has_brazilian_stripe_connect_account?).and_return(false)
          allow(seller).to receive(:has_brazilian_stripe_connect_account?).and_return(true)
        end

        it "is invalid" do
          expect(direct_affiliate).not_to be_valid
          expect(direct_affiliate.errors[:base]).to include(
            "You cannot add an affiliate because you are using a Brazilian Stripe account."
          )
        end
      end

      context "when neither user has a Brazilian Stripe Connect account" do
        before do
          allow(seller).to receive(:has_brazilian_stripe_connect_account?).and_return(false)
          allow(affiliate_user).to receive(:has_brazilian_stripe_connect_account?).and_return(false)
        end

        it "is valid" do
          expect(direct_affiliate).to be_valid
        end
      end
    end
  end

  describe "flags" do
    it "has a `apply_to_all_products` flag" do
      flag_on = create(:direct_affiliate, apply_to_all_products: true)
      flag_off = create(:direct_affiliate, apply_to_all_products: false)

      expect(flag_on.apply_to_all_products).to be true
      expect(flag_off.apply_to_all_products).to be false
    end

    it "has a `send_posts` flag" do
      flag_on = create(:direct_affiliate, send_posts: true)
      flag_off = create(:direct_affiliate, send_posts: false)

      expect(flag_on.send_posts).to be true
      expect(flag_off.send_posts).to be false
    end
  end

  describe "destination_url validation" do
    let(:affiliate) { build(:direct_affiliate) }

    it "does not allow invalid destination urls" do
      affiliate.destination_url = "saywhat"
      expect(affiliate.valid?).to be(false)

      affiliate.destination_url = "saywhat.com"
      expect(affiliate.valid?).to be(false)

      affiliate.destination_url = "httpsaywhat.com"
      expect(affiliate.valid?).to be(false)

      affiliate.destination_url = "ftp://saywhat.com"
      expect(affiliate.valid?).to be(false)
    end

    it "allows valid destination urls" do
      affiliate.destination_url = "http://saywhat.com/something?this=that"
      expect(affiliate.valid?).to be(true)

      affiliate.destination_url = "https://saywhat.com"
      expect(affiliate.valid?).to be(true)
    end
  end

  describe ".cookie_lifetime" do
    it "returns 30 days" do
      expect(described_class.cookie_lifetime).to eq 30.days
    end
  end

  describe "#final_destination_url", :elasticsearch_wait_for_refresh do
    let(:affiliate) { create(:direct_affiliate, destination_url:) }
    let(:seller) { affiliate.seller }

    context "when destination URL is set" do
      let(:destination_url) { "https://gumroad.com/foo" }

      context "when apply_to_all_products is false" do
        it "returns the seller subdomain" do
          expect(affiliate.final_destination_url).to eq seller.subdomain_with_protocol
        end
      end

      context "when apply_to_all_products is true" do
        it "returns the destination URL" do
          affiliate.update!(apply_to_all_products: true)
          expect(affiliate.final_destination_url(product:)).to eq destination_url
        end
      end
    end

    context "when destination URL is not set" do
      let(:destination_url) { nil }

      context "but product is provided" do
        let(:product) { create(:product, user: affiliate.seller) }

        it "returns the product destination URL if it exists" do
          create(:product_affiliate, affiliate:, product:, destination_url: "https://gumroad.com/bar")
          expect(affiliate.final_destination_url(product:)).to eq "https://gumroad.com/bar"
        end

        it "returns the product URL if they're an affiliate for that product" do
          affiliate.products << product
          expect(affiliate.final_destination_url(product:)).to eq product.long_url
        end

        context "but is not affiliated" do
          it "returns the sole affiliated product's URL if they are affiliated for a single product" do
            affiliated_product = create(:product, user: seller)
            affiliate.products << affiliated_product
            expect(affiliate.final_destination_url(product:)).to eq affiliated_product.long_url
          end

          it "returns the seller subdomain if they are an affiliate for all products" do
            affiliate.update!(apply_to_all_products: true)
            affiliate.products << create(:product, user: seller)
            affiliate.products << create(:product, user: seller)
            expect(affiliate.final_destination_url(product:)).to eq seller.subdomain_with_protocol
          end

          it "falls back to the seller subdomain if it exists" do
            expect(affiliate.final_destination_url(product:)).to eq seller.subdomain_with_protocol
          end
        end
      end

      context "and product is not provided" do
        context "and they are affiliated for a single product" do
          it "returns the affiliated product's URL" do
            affiliated_product = create(:product, user: seller)
            affiliate.products << affiliated_product
            expect(affiliate.final_destination_url).to eq affiliated_product.long_url
          end

          it "returns the product's destination URL if it is set" do
            create(:product_affiliate, affiliate:, product: create(:product, user: seller), destination_url: "https://gumroad.com/bar")
            expect(affiliate.final_destination_url).to eq "https://gumroad.com/bar"
          end
        end

        it "returns the seller subdomain if they are an affiliate for all products" do
          affiliate.update!(apply_to_all_products: true)
          affiliated_product = create(:product, user: seller)
          affiliate.products << affiliated_product
          expect(affiliate.final_destination_url).to eq seller.subdomain_with_protocol
        end

        it "falls back to the seller subdomain" do
          expect(affiliate.final_destination_url).to eq seller.subdomain_with_protocol
        end
      end

      context "when seller username is set" do
        before do
          seller.update!(username: "barnabas")
        end

        context "when apply_to_all_products is false" do
          it "returns the last product url when destination URL is set on the affiliate" do
            direct_affiliate.destination_url = "https://saywhat.com"
            expect(direct_affiliate.final_destination_url).to eq(product.long_url)
          end

          it "falls back to user profile page url if the affiliate is associated with multiple products" do
            direct_affiliate.products << create(:product)
            expect(direct_affiliate.final_destination_url).to eq(seller.subdomain_with_protocol)
          end
        end

        context "when apply_to_all_products is true" do
          it "falls back to the user profile page even if only 1 affiliated product" do
            direct_affiliate.apply_to_all_products = true
            direct_affiliate.save!
            expect(direct_affiliate.final_destination_url).to eq(seller.subdomain_with_protocol)
          end
        end
      end
    end
  end

  describe "schedule_workflow_jobs" do
    let!(:affiliate_workflow) do
      workflow = create(:workflow, seller:, link: nil, workflow_type: Workflow::AFFILIATE_TYPE, published_at: 1.week.ago)
      create_list(:installment, 2, workflow:).each do |post|
        create(:installment_rule, installment: post, delayed_delivery_time: 3.days)
      end
      workflow
    end
    let!(:seller_workflow) do
      workflow = create(:workflow, seller:, link: nil, workflow_type: Workflow::SELLER_TYPE, published_at: 1.week.ago)
      create(:installment_rule, delayed_delivery_time: 1.day, installment: create(:installment, workflow:))
      workflow
    end

    it "enqueues 2 installment jobs when an affiliate is created" do
      direct_affiliate.schedule_workflow_jobs

      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(2)
    end

    it "does not enqueue installment jobs when the workflow is marked as member_cancellation and an affiliate is created" do
      affiliate_workflow.update!(workflow_trigger: "member_cancellation")

      direct_affiliate.schedule_workflow_jobs

      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
    end
  end

  describe "#send_invitation_email after_commit callback" do
    context "when prevent_sending_invitation_email is set to true" do
      it "does not send invitation email" do
        expect do
          create(:direct_affiliate, prevent_sending_invitation_email: true)
        end.to_not have_enqueued_mail(AffiliateMailer, :direct_affiliate_invitation)
      end
    end

    context "when prevent_sending_invitation_email is not set" do
      it "sends invitation email" do
        expect do
          create(:direct_affiliate)
        end.to have_enqueued_mail(AffiliateMailer, :direct_affiliate_invitation)
      end
    end

    context "when prevent_sending_invitation_email_to_seller is set" do
      it "enqueues the invitation mail with prevent_sending_invitation_email_to_seller set to true" do
        expect do
          create(:direct_affiliate, prevent_sending_invitation_email_to_seller: true)
        end.to have_enqueued_mail(AffiliateMailer, :direct_affiliate_invitation).with(anything, true)
      end
    end
  end

  describe "#update_posts_subscription" do
    it "updates affiliate user's all affiliate records for the creator as per send_posts parameter" do
      direct_affiliate_2 = create(:direct_affiliate, affiliate_user:, seller:, deleted_at: Time.current)
      direct_affiliate.update_posts_subscription(send_posts: false)

      expect(direct_affiliate.reload.send_posts).to be false
      expect(direct_affiliate_2.reload.send_posts).to be false

      direct_affiliate.update_posts_subscription(send_posts: true)

      expect(direct_affiliate.reload.send_posts).to be true
      expect(direct_affiliate_2.reload.send_posts).to be true
    end
  end

  describe "#eligible_for_purchase_credit?" do
    let(:affiliate) { create(:direct_affiliate) }
    let(:product) { create(:product, user: affiliate.seller) }

    context "when affiliated with the product" do
      before do
        affiliate.products << product
      end

      it "returns true if the purchase did not come through Discover" do
        expect(affiliate.eligible_for_purchase_credit?(product:, was_recommended: false)).to eq true
      end

      it "returns false if the purchase came through Discover" do
        expect(affiliate.eligible_for_purchase_credit?(product:, was_recommended: true)).to eq false
      end

      it "returns false if the affiliate is suspended" do
        user = affiliate.affiliate_user
        admin = create(:admin_user)
        user.flag_for_fraud!(author_id: admin.id)
        user.suspend_for_fraud!(author_id: admin.id)
        expect(affiliate.eligible_for_purchase_credit?(product:)).to eq false
      end
    end

    it "returns false if the affiliate is not affiliated for the product" do
      expect(affiliate.eligible_for_purchase_credit?(product:)).to eq false
    end

    it "returns false if the affiliate is deleted" do
      affiliate = create(:direct_affiliate, deleted_at: 1.day.ago, products: [product])
      expect(affiliate.eligible_for_purchase_credit?(product:)).to eq false
    end

    it "returns false if affiliated user is using a Brazilian Stripe Connect account" do
      expect(affiliate.eligible_for_credit?).to be true

      brazilian_stripe_account = create(:merchant_account_stripe_connect, user: affiliate.affiliate_user, country: "BR")
      affiliate.affiliate_user.update!(check_merchant_account_is_linked: true)
      expect(affiliate.affiliate_user.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

      expect(affiliate.eligible_for_credit?).to be false
    end
  end

  describe "#basis_points" do
    let(:affiliate) { create(:direct_affiliate, apply_to_all_products:, affiliate_basis_points: 10_00) }
    let(:product_affiliate) { create(:product_affiliate, affiliate:, affiliate_basis_points: product_affiliate_basis_points) }

    context "when no product_id is provided" do
      let(:product_affiliate_basis_points) { nil }

      context "when the affiliate applies to all products" do
        let(:apply_to_all_products) { true }

        it "returns the affiliate's basis points" do
          expect(affiliate.basis_points).to eq 10_00
        end
      end

      context "when the affiliate does not apply to all products" do
        let(:apply_to_all_products) { false }

        it "returns the affiliate's basis points" do
          expect(affiliate.basis_points).to eq 10_00
        end
      end
    end

    context "when product_id is provided" do
      context "when the affiliate applies to all products" do
        let(:apply_to_all_products) { true }
        let(:product_affiliate_basis_points) { 20_00 }

        it "returns the affiliate's basis points" do
          expect(affiliate.basis_points(product_id: product_affiliate.link_id)).to eq 10_00
        end
      end

      context "when affiliate does not apply to all products" do
        let(:apply_to_all_products) { false }

        context "and product affiliate commission is set" do
          let(:product_affiliate_basis_points) { 20_00 }

          it "returns the product affiliate's basis points" do
            expect(affiliate.basis_points(product_id: product_affiliate.link_id)).to eq 20_00
          end
        end

        context "and product affiliate commission is not set" do
          let(:product_affiliate_basis_points) { nil }

          it "returns the affiliate's basis points" do
            expect(affiliate.basis_points(product_id: product_affiliate.link_id)).to eq 10_00
          end
        end
      end
    end
  end

  context "AudienceMember" do
    let(:affiliate) { create(:direct_affiliate) }

    describe "#should_be_audience_member?" do
      it "only returns true for expected cases" do
        affiliate = create(:direct_affiliate)
        expect(affiliate.should_be_audience_member?).to eq(true)

        affiliate = create(:direct_affiliate, send_posts: false)
        expect(affiliate.should_be_audience_member?).to eq(false)

        affiliate = create(:direct_affiliate, deleted_at: Time.current)
        expect(affiliate.should_be_audience_member?).to eq(false)

        affiliate = create(:direct_affiliate, deleted_at: Time.current)
        expect(affiliate.should_be_audience_member?).to eq(false)

        affiliate = create(:direct_affiliate)
        affiliate.affiliate_user.update_column(:email, nil)
        expect(affiliate.should_be_audience_member?).to eq(false)
        affiliate.affiliate_user.update_column(:email, "some-invalid-email")
        expect(affiliate.should_be_audience_member?).to eq(false)
      end
    end

    it "adds member when product is added" do
      member_relation = AudienceMember.where(seller: affiliate.seller, email: affiliate.affiliate_user.email)
      expect(member_relation.exists?).to eq(false)

      affiliate.products << create(:product, user: affiliate.seller)
      affiliate.products << create(:product, user: affiliate.seller)
      expect(member_relation.count).to eq(1)

      create(:product_affiliate, affiliate:, product: create(:product, user: affiliate.seller))
      member = member_relation.first
      expect(member.details["affiliates"].size).to eq(3)
      expect(member.details["affiliates"].map { _1["product_id"] }).to match_array(affiliate.products.map(&:id))
    end

    it "removes member when product affiliation is removed" do
      member_relation = AudienceMember.where(seller: affiliate.seller, email: affiliate.affiliate_user.email)
      affiliate.products << create(:product, user: affiliate.seller)
      affiliate.products << create(:product, user: affiliate.seller)
      products = affiliate.products.to_a

      member = member_relation.first
      ProductAffiliate.find_by(affiliate:, product: products.first).destroy!

      member.reload
      expect(member.details["affiliates"].size).to eq(1)
      expect(member.details["affiliates"].map { _1["product_id"] }).to match_array([products.second.id])

      affiliate.products.delete(products.second)

      expect do
        member.reload
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "removes the member when the affiliate user unsubscribes from a seller post" do
      affiliate = create(:direct_affiliate)
      product = create(:product, user: affiliate.seller)
      affiliate.products << product

      member_relation = AudienceMember.where(seller: affiliate.seller, email: affiliate.affiliate_user.email)
      expect(member_relation.exists?).to eq(true)

      affiliate.update(send_posts: false)

      expect(member_relation.exists?).to eq(false)
    end
  end

  describe "#product_sales_info" do
    let(:affiliate) { create(:direct_affiliate) }
    let(:product) { create(:product, user: affiliate.seller, name: "Product") }
    let(:archived_product) { create(:product, user: affiliate.seller, name: "Archived", archived: true) }
    let(:deleted_product) { create(:product, user: affiliate.seller, name: "Deleted", deleted_at: 2.days.ago) }
    let!(:product_without_affiliate_sales) { create(:product, user: affiliate.seller, archived: true) }

    before do
      create(:product_affiliate, affiliate:, product:, affiliate_basis_points: 40_00, destination_url: "https://example.com")
      create(:product_affiliate, affiliate:, product: archived_product, affiliate_basis_points: 40_00, destination_url: "https://example.com")
      create(:product_affiliate, affiliate:, product: deleted_product, affiliate_basis_points: 20_00, destination_url: "https://example.com")

      create(:purchase_with_balance, link: deleted_product, affiliate_credit_cents: 100, affiliate:)
      create(:purchase_with_balance, link: product, affiliate_credit_cents: 100, affiliate:)
      create_list(:purchase_with_balance, 2, link: archived_product, affiliate_credit_cents: 100, affiliate:)
    end

    it "returns sales data for products with affiliate sales" do
      expect(affiliate.product_sales_info).to eq(
        product.external_id_numeric => { volume_cents: 100, sales_count: 1 },
        archived_product.external_id_numeric => { volume_cents: 200, sales_count: 2 },
        deleted_product.external_id_numeric => { volume_cents: 100, sales_count: 1 }
      )
    end
  end

  describe "#as_json" do
    let(:affiliate_user) { create(:affiliate_user, username: "creator") }
    let(:affiliate) { create(:direct_affiliate, affiliate_user:, apply_to_all_products: true) }
    let!(:product) { create(:product, name: "Gumbot bits", user: affiliate.seller) }

    before do
      create(:product_affiliate, affiliate:, product:, affiliate_basis_points: affiliate.affiliate_basis_points, destination_url: "https://example.com")
    end

    it "returns a hash of custom attributes" do
      create(:product, name: "Unaffiliated product we ignore", user: affiliate.seller)
      create(:product, name: "Unaffiliated product we ignore 2", user: affiliate.seller)

      expect(affiliate.as_json).to eq(
        {
          email: affiliate_user.email,
          destination_url: affiliate.destination_url,
          affiliate_user_name: "creator",
          fee_percent: 3,
          id: affiliate.external_id,
          apply_to_all_products: false,
          products: [
            {
              id: product.external_id_numeric,
              name: "Gumbot bits",
              fee_percent: 3,
              referral_url: affiliate.referral_url_for_product(product),
              destination_url: "https://example.com",
            }
          ],
          product_referral_url: affiliate.referral_url_for_product(product),
        }
      )
    end

    context "when affiliate has multiple products with the same commission percentage" do
      let(:product2) { create(:product, name: "ChatGPT4 prompts", user: affiliate.seller, archived: true) }
      let(:product3) { create(:product, name: "Beautiful banner", user: affiliate.seller) }

      before do
        create(:product_affiliate, affiliate:, product: product2, affiliate_basis_points: affiliate.affiliate_basis_points)
        create(:product_affiliate, affiliate:, product: product3, affiliate_basis_points: affiliate.affiliate_basis_points)
      end

      it "returns a hash of custom attributes with apply_to_all_products set to true" do
        expect(affiliate.as_json).to eq(
          {
            email: affiliate_user.email,
            destination_url: affiliate.destination_url,
            affiliate_user_name: "creator",
            fee_percent: 3,
            id: affiliate.external_id,
            apply_to_all_products: true,
            products: [
              {
                id: product.external_id_numeric,
                name: "Gumbot bits",
                fee_percent: 3,
                referral_url: affiliate.referral_url_for_product(product),
                destination_url: "https://example.com",
              },
              {
                id: product2.external_id_numeric,
                name: "ChatGPT4 prompts",
                fee_percent: 3,
                referral_url: affiliate.referral_url_for_product(product2),
                destination_url: nil,
              },
              {
                id: product3.external_id_numeric,
                name: "Beautiful banner",
                fee_percent: 3,
                referral_url: affiliate.referral_url_for_product(product3),
                destination_url: nil,
              }
            ],
            product_referral_url: affiliate.referral_url,
          }
        )
      end
    end

    context "when affiliate has multiple products with product-specific commission percentages" do
      let(:product_2) { create(:product, name: "ChatGPT4 prompts", user: affiliate.seller) }
      let(:product_3) { create(:product, name: "Beautiful banner", user: affiliate.seller) }

      before do
        create(:product_affiliate, affiliate:, product: product_2, affiliate_basis_points: 45_00)
        create(:product_affiliate, affiliate:, product: product_3, affiliate_basis_points: 23_00)
      end

      it "returns a hash of custom attributes with apply_to_all_products set to false" do
        expect(affiliate.as_json).to eq(
          {
            email: affiliate_user.email,
            destination_url: affiliate.destination_url,
            affiliate_user_name: "creator",
            fee_percent: 3,
            id: affiliate.external_id,
            apply_to_all_products: false,
            products: [
              {
                id: product.external_id_numeric,
                name: "Gumbot bits",
                fee_percent: 3,
                referral_url: affiliate.referral_url_for_product(product),
                destination_url: "https://example.com",
              },
              {
                id: product_2.external_id_numeric,
                name: "ChatGPT4 prompts",
                fee_percent: 45,
                referral_url: affiliate.referral_url_for_product(product_2),
                destination_url: nil,
              },
              {
                id: product_3.external_id_numeric,
                name: "Beautiful banner",
                fee_percent: 23,
                referral_url: affiliate.referral_url_for_product(product_3),
                destination_url: nil,
              }
            ],
            product_referral_url: affiliate.referral_url,
          }
        )
      end
    end
  end

  describe "#products_data" do
    let(:affiliate) { create(:direct_affiliate) }
    let(:product) { create(:product, user: affiliate.seller, name: "Product") }
    let!(:unaffiliated_product) { create(:product, user: affiliate.seller, name: "Unaffiliated Product") }
    let(:archived_product) { create(:product, user: affiliate.seller, name: "Archived", archived: true) }
    let!(:other_archived_product) { create(:product, user: affiliate.seller, archived: true) }
    let!(:ineligible_product) { create(:product, :is_collab, user: affiliate.seller, name: "Ineligible Product") }

    before do
      create(:product_affiliate, affiliate:, product:, affiliate_basis_points: 40_00, destination_url: "https://example.com")
      create(:product_affiliate, affiliate:, product: archived_product, affiliate_basis_points: 40_00, destination_url: "https://example.com")
    end

    it "returns data for all products" do
      expect(affiliate.products_data).to eq(
        [
          {
            destination_url: "https://example.com",
            enabled: true,
            fee_percent: 40,
            id: product.external_id_numeric,
            name: "Product",
            referral_url: affiliate.referral_url_for_product(product),
            sales_count: 0,
            volume_cents: 0
          },
          {
            destination_url: "https://example.com",
            enabled: true,
            fee_percent: 40,
            id: archived_product.external_id_numeric,
            name: "Archived",
            referral_url: affiliate.referral_url_for_product(archived_product),
            sales_count: 0,
            volume_cents: 0
          },
          {
            destination_url: nil,
            enabled: false,
            fee_percent: 3,
            id: unaffiliated_product.external_id_numeric,
            name: "Unaffiliated Product",
            referral_url: affiliate.referral_url_for_product(unaffiliated_product),
            sales_count: 0,
            volume_cents: 0
          }
        ])
    end

    context "when affiliate has credits" do
      before do
        create_list(:purchase_with_balance, 2, affiliate_credit_cents: 100, affiliate:, link: product)
        create(:purchase_with_balance, affiliate_credit_cents: 100, affiliate:, link: archived_product)
      end

      it "returns the correct data" do
        expect(affiliate.products_data).to eq(
          [
            {
              destination_url: "https://example.com",
              enabled: true,
              fee_percent: 40,
              id: product.external_id_numeric,
              name: "Product",
              referral_url: affiliate.referral_url_for_product(product),
              sales_count: 2,
              volume_cents: 200
            },
            {
              destination_url: "https://example.com",
              enabled: true,
              fee_percent: 40,
              id: archived_product.external_id_numeric,
              name: "Archived",
              referral_url: affiliate.referral_url_for_product(archived_product),
              sales_count: 1,
              volume_cents: 100
            },
            {
              destination_url: nil,
              enabled: false,
              fee_percent: 3,
              id: unaffiliated_product.external_id_numeric,
              name: "Unaffiliated Product",
              referral_url: affiliate.referral_url_for_product(unaffiliated_product),
              sales_count: 0,
              volume_cents: 0
            }
          ])
      end
    end
  end
end
