# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "with workflow form 'context' in response" do
  let!(:product1) { create(:product_with_digital_versions, name: "Product 1", user:) }
  let!(:product2) { create(:product, name: "Product 2", user:, archived: true) }
  let!(:membership) { create(:membership_product, name: "Membership product", user:) }
  let!(:physical_product) { create(:physical_product, name: "Physical product", user:, skus_enabled: true) }
  let!(:sku1) { create(:sku, link: physical_product, name: "Blue - Large") }
  let!(:sku2) { create(:sku, link: physical_product, name: "Green - Small") }

  it "includes workflow form 'context' in the response" do
    expect(result.keys).to include(:context)
    expect(result[:context].keys).to match_array(%i[products_and_variant_options affiliate_product_options timezone currency_symbol countries aws_access_key_id gumroad_address s3_url user_id eligible_for_abandoned_cart_workflows])
    expect(result[:context][:products_and_variant_options]).to match_array([
                                                                             { id: product1.unique_permalink, label: "Product 1", product_permalink: product1.unique_permalink, archived: false, type: "product" },
                                                                             { id: product1.alive_variants.first.external_id, label: "Product 1 — Untitled 1", product_permalink: product1.unique_permalink, archived: false, type: "variant" },
                                                                             { id: product1.alive_variants.second.external_id, label: "Product 1 — Untitled 2", product_permalink: product1.unique_permalink, archived: false, type: "variant" },
                                                                             { id: membership.unique_permalink, label: "Membership product", product_permalink: membership.unique_permalink, archived: false, type: "product" },
                                                                             { id: membership.tiers.first.external_id, label: "Membership product — Untitled", product_permalink: membership.unique_permalink, archived: false, type: "variant" },
                                                                             { id: physical_product.unique_permalink, label: "Physical product", product_permalink: physical_product.unique_permalink, archived: false, type: "product" },
                                                                             { id: sku1.external_id, label: "Physical product — Blue - Large", product_permalink: physical_product.unique_permalink, archived: false, type: "variant" },
                                                                             { id: sku2.external_id, label: "Physical product — Green - Small", product_permalink: physical_product.unique_permalink, archived: false, type: "variant" },
                                                                           ])
    expect(result[:context][:affiliate_product_options]).to match_array([
                                                                          { id: product1.unique_permalink, label: "Product 1", product_permalink: product1.unique_permalink, archived: false, type: "product" },
                                                                          { id: membership.unique_permalink, label: "Membership product", product_permalink: membership.unique_permalink, archived: false, type: "product" },
                                                                          { id: physical_product.unique_permalink, label: "Physical product", product_permalink: physical_product.unique_permalink, archived: false, type: "product" },
                                                                        ])
    timezone = ActiveSupport::TimeZone[user.timezone].now.strftime("%Z")
    expect(result[:context][:timezone]).to eq(timezone)
    expect(result[:context][:currency_symbol]).to eq("$")
    expect(result[:context][:countries]).to match_array(["United States"] + Compliance::Countries.for_select.map { _1.last }.without("United States"))
    expect(result[:context][:aws_access_key_id]).to eq(AWS_ACCESS_KEY)
    expect(result[:context][:s3_url]).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}")
    expect(result[:context][:user_id]).to eq(user.external_id)
    expect(result[:context][:gumroad_address]).to eq(GumroadAddress.full)
    expect(result[:context][:eligible_for_abandoned_cart_workflows]).to eq(user.eligible_for_abandoned_cart_workflows?)
  end
end
