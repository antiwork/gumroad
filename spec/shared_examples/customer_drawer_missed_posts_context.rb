# frozen_string_literal: true

require "spec_helper"

RSpec.shared_context "customer drawer missed posts setup" do
  let(:seller) { create(:user) }
  let(:product_a) { create(:product, user: seller) }
  let(:product_b) { create(:product, user: seller) }
  let(:product_c) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product_a, seller:) }

  let!(:audience_installment) { create(:audience_installment, seller:) }
  let!(:follower_installment) { create(:follower_post, seller:) }
  let!(:affiliate_installment) { create(:affiliate_installment, seller:) }
  let!(:abandoned_cart_installment) { create(:abandoned_cart_workflow, seller:) }

  let!(:product_a_variant_category) { create(:variant_category, link: product_a) }
  let!(:product_a_variant) { create(:variant, variant_category: product_a_variant_category) }
  let!(:product_b_variant_category) { create(:variant_category, link: product_b) }
  let!(:product_b_variant) { create(:variant, variant_category: product_b_variant_category) }
  let!(:product_c_variant_category) { create(:variant_category, link: product_c) }
  let!(:product_c_variant) { create(:variant, variant_category: product_c_variant_category) }

  let!(:seller_workflow) { create(:workflow, seller:, link: nil, workflow_type: Workflow::SELLER_TYPE, published_at: Time.current) }

  let!(:seller_post_to_all_customers) { create(:seller_installment, seller:, published_at: Time.current) }
  let!(:seller_workflow_post_to_all_customers) { create(:seller_installment, link_id: nil, seller:, workflow: seller_workflow, published_at: Time.current) }
  let!(:seller_post_with_bought_products_filter_product_a_and_c) { create(:seller_installment, seller:, bought_products: [product_a.unique_permalink, product_c.unique_permalink], published_at: Time.current) }
  let!(:seller_post_with_bought_variants_filter_product_a_and_c_variant) { create(:seller_installment, seller:, bought_variants: [product_a_variant.external_id, product_c_variant.external_id], published_at: Time.current) }

  let!(:regular_post_product_a) { create(:product_installment, link: product_a, seller:, published_at: Time.current) }
  let!(:regular_post_product_a_variant) { create(:variant_installment, base_variant: product_a_variant, link: product_a, seller:, published_at: Time.current) }
  let!(:workflow_post_product_a) { create(:workflow_installment, link: product_a, seller:, workflow: create(:workflow, seller:, link: product_a, published_at: Time.current), published_at: Time.current) }
  let!(:workflow_post_product_a_variant) { create(:workflow_installment, link: product_a, seller:, workflow: create(:variant_workflow, seller:, link: product_a, base_variant: product_a_variant, published_at: Time.current), published_at: Time.current) }

  let!(:regular_post_product_b) { create(:product_installment, link: product_b, seller:) }
  let!(:regular_post_product_b_variant) { create(:variant_installment, base_variant: product_b_variant, link: product_b, seller:) }
  let!(:workflow_post_product_b) { create(:workflow_installment, link: product_b, seller:) }
  let!(:product_b_variant_workflow) { create(:variant_workflow, seller:, link: product_b, base_variant: product_b_variant, published_at: Time.current) }
  let!(:workflow_post_product_b_variant) { create(:workflow_installment, link: product_b, seller:, workflow: product_b_variant_workflow, published_at: Time.current) }
end

RSpec.shared_context "with bundle purchase setup" do |with_posts: false|
  before do
    missing_vars = [:seller, :product_a, :product_b, :product_a_variant, :product_b_variant].reject { respond_to?(_1) }

    if missing_vars.any?
      raise ArgumentError,
            "with bundle purchase setup requires 'customer drawer missed posts setup' context. " \
            "Missing variables: #{missing_vars.join(', ')}. " \
            "Please include the parent context first: include_context 'customer drawer missed posts setup'"
    end
  end

  let(:bundle) { create(:product, :bundle, user: seller) }
  let(:bundle_purchase) { create(:purchase, link: bundle, seller:) }

  let!(:bundle_product_a) { create(:bundle_product, bundle: bundle, product: product_a, variant: product_a_variant) }
  let!(:bundle_product_b) { create(:bundle_product, bundle: bundle, product: product_b, variant: product_b_variant) }

  before { bundle_purchase.create_artifacts_and_send_receipt! }

  if with_posts
    let!(:bundle_post) { create(:installment, link: bundle, seller: seller, published_at: Time.current) }
    let!(:bundle_workflow) { create(:workflow, seller: seller, link: bundle, published_at: Time.current) }
    let!(:bundle_workflow_post) { create(:workflow_installment, link: bundle, workflow: bundle_workflow, seller: seller, published_at: Time.current) }
  end
end
