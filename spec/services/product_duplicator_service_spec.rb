# frozen_string_literal: true

require "spec_helper"

describe ProductDuplicatorService do
  let(:seller) { create(:user) }
  let(:s3_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3" }
  let(:product) do
    product_params = { user: seller, price_cents: 5000, name: "test product",
                       description: "description for test product",
                       is_recurring_billing: true, subscription_duration: "monthly",
                       is_in_preorder_state: true,
                       custom_permalink: "joker", is_adult: "1" }
    create(:product, product_params)
  end
  let!(:product_refund_policy) { create(:product_refund_policy, product:) }

  before do
    product.update!(product_refund_policy_enabled: true)
  end

  it "duplicates the product and marks the duplicate product as draft" do
    file_params = [{ external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png" },
                   { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf" }]
    product.save_files!(file_params)

    variant_category = create(:variant_category, title: "sizes", link: product)
    variant_category2 = create(:variant_category, title: "colors", link: product)
    variant = create(:variant, variant_category:, name: "small")
    variant2 = create(:variant, variant_category: variant_category2, name: "red")
    variant3 = create(:variant, variant_category: variant_category2, name: "blue")
    sku = create(:sku, link: product, name: "small - red")
    sku2 = create(:sku, link: product, name: "small - blue")
    variant.skus << sku << sku2
    variant2.skus << sku
    variant3.skus << sku2

    shipping_destination = ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
    shipping_destination2 = ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)
    product.shipping_destinations << shipping_destination << shipping_destination2

    tags = { one: "digital", two: "comic", three: "joker" }
    product.save_tags!(tags)

    offercode = create(:percentage_offer_code, code: "oc1", products: [product], amount_percentage: 50)
    offercode2 = create(:percentage_offer_code, code: "oc2", products: [product], amount_percentage: 100, amount_cents: nil)
    offercode3 = create(:offer_code, code: "oc3", products: [product], amount_cents: 200)
    universal_offer_code = create(:universal_offer_code, code: "uoc1", user: product.user)

    asset = create(:asset_preview_gif, link: product)
    asset2 = create(:asset_preview, link: product)

    preorder_link = create(:preorder_link, link: product, url: s3_url)
    preorder_link.update_attribute(:release_at, 1.month.from_now.round)

    tpa_params = [
      product: product.unique_permalink,
      code: "<span>Third party analytics</span>",
      location: "receipt",
    ]
    ThirdPartyAnalytic.save_third_party_analytics(tpa_params, seller)

    product.save!

    duplicate_product = ProductDuplicatorService.new(product.id).duplicate

    do_not_compare = %w[id name unique_permalink custom_permalink draft purchase_disabled_at created_at updated_at]
    expect(duplicate_product.instance_of?(Link)).to be true
    expect(duplicate_product.unique_permalink).to_not be(nil)
    expect(duplicate_product.custom_permalink).to be(nil)
    expect(duplicate_product.name).to eq "#{product.name} (copy)"
    expect(duplicate_product.draft).to be(true)
    expect(duplicate_product.purchase_disabled_at).to_not be(nil)
    expect(duplicate_product.attributes.except(*do_not_compare)).to eq(product.attributes.except(*do_not_compare))

    do_not_compare = %w[id link_id created_at updated_at]
    expect(duplicate_product.prices.alive.first.attributes.except(*do_not_compare)).to eq(product.prices.alive.first.attributes.except(*do_not_compare))

    expect(duplicate_product.product_files.count).to eq(2)
    expect(duplicate_product.product_files.first.url).to eq(file_params[0][:url])
    expect(duplicate_product.product_files.last.url).to eq(file_params[1][:url])

    expect(duplicate_product.variant_categories.count).to eq(2)
    expect(duplicate_product.variant_categories.first.title).to eq(variant_category.title)
    expect(duplicate_product.variant_categories.last.title).to eq(variant_category2.title)
    expect(duplicate_product.variant_categories.first.variants.count).to eq(1)
    expect(duplicate_product.variant_categories.first.variants.first.name).to eq(variant.name)
    expect(duplicate_product.variant_categories.last.variants.count).to eq(2)
    expect(duplicate_product.variant_categories.last.variants.first.name).to eq(variant2.name)
    expect(duplicate_product.variant_categories.last.variants.last.name).to eq(variant3.name)
    expect(duplicate_product.skus.count).to eq(2)
    expect(duplicate_product.skus.first.name).to eq(sku.name)
    expect(duplicate_product.skus.last.name).to eq(sku2.name)
    expect(duplicate_product.variant_categories.first.variants.first.skus.count).to eq(2)
    expect(duplicate_product.variant_categories.first.variants.first.skus.first.name).to eq(sku.name)
    expect(duplicate_product.variant_categories.first.variants.first.skus.last.name).to eq(sku2.name)
    expect(duplicate_product.variant_categories.last.variants.first.skus.count).to eq(1)
    expect(duplicate_product.variant_categories.last.variants.first.skus.first.name).to eq(sku.name)
    expect(duplicate_product.variant_categories.last.variants.last.skus.count).to eq(1)
    expect(duplicate_product.variant_categories.last.variants.last.skus.first.name).to eq(sku2.name)

    expect(duplicate_product.shipping_destinations.size).to eq(2)
    expect(duplicate_product.shipping_destinations.alive.size).to eq(product.shipping_destinations.alive.size)
    expect(duplicate_product.shipping_destinations.alive.first.country_code).to eq(Product::Shipping::ELSEWHERE)
    expect(duplicate_product.shipping_destinations.alive.last.country_code).to eq(Compliance::Countries::DEU.alpha2)

    expect(duplicate_product.product_taggings.size).to eq(tags.size)
    expect(duplicate_product.tags.size).to eq(tags.size)
    expect(duplicate_product.tags.first.name).to eq(tags[:one])
    expect(duplicate_product.tags.second.name).to eq(tags[:two])
    expect(duplicate_product.tags.last.name).to eq(tags[:three])

    expect(duplicate_product.offer_codes.size).to eq(3)
    expect(duplicate_product.product_and_universal_offer_codes.size).to eq(4)
    all_offer_codes = duplicate_product.product_and_universal_offer_codes
    expect(all_offer_codes.first.code).to eq(offercode.code)
    expect(all_offer_codes.first.amount_percentage).to eq(offercode.amount_percentage)
    expect(all_offer_codes.second.code).to eq(offercode2.code)
    expect(all_offer_codes.second.amount_percentage).to eq(offercode2.amount_percentage)
    expect(all_offer_codes.third.code).to eq(offercode3.code)
    expect(all_offer_codes.third.amount_cents).to eq(offercode3.amount_cents)
    expect(all_offer_codes.last.code).to eq(universal_offer_code.code)
    expect(all_offer_codes.last.amount_cents).to eq(universal_offer_code.amount_cents)

    expect(duplicate_product.asset_previews.count).to eq(2)
    expect(duplicate_product.asset_previews.first.guid).to eq(asset.guid)
    expect(duplicate_product.asset_previews.last.guid).to eq(asset2.guid)

    do_not_compare = %w[id link_id created_at updated_at]
    expect(duplicate_product.preorder_link.attributes.except(*do_not_compare)).to eq(product.preorder_link.attributes.except(*do_not_compare))

    expect(duplicate_product.is_recurring_billing).to be(true)
    expect(duplicate_product.subscription_duration).to eq("monthly")

    expect(duplicate_product.third_party_analytics.count).to eq(1)
    expect(duplicate_product.third_party_analytics.first.analytics_code).to eq("<span>Third party analytics</span>")

    expect(duplicate_product.is_adult).to be(true)

    expect(duplicate_product.product_refund_policy_enabled?).to be(true)
    expect(duplicate_product.product_refund_policy.title).to eq(product.product_refund_policy.title)
    expect(duplicate_product.product_refund_policy.fine_print).to eq(product.product_refund_policy.fine_print)
  end

  it "duplicates the product and marks is_duplicating as false" do
    product.update!(is_duplicating: true)

    duplicate_product = ProductDuplicatorService.new(product.id).duplicate

    expect(duplicate_product.is_duplicating).to be false
  end

  it "maintains atomicity and rolls back the transaction if some error occurs in the middle" do
    duplicate_product = nil
    allow_any_instance_of(ProductDuplicatorService).to receive(:duplicate_third_party_analytics).and_raise(RuntimeError)
    expect do
      duplicate_product = ProductDuplicatorService.new(product.id).duplicate
    end.to raise_error(RuntimeError)
    expect(duplicate_product).to be(nil)
    expect(Link.where(name: "#{product.name} (copy)").count).to eq(0)
  end

  it "duplicates released preorder product and sets the new release_at as 1 month from now" do
    preorder_link = create(:preorder_link, link: product, url: s3_url)
    preorder_link.update_attribute(:release_at, 1.day.ago.round)

    duplicate_product = ProductDuplicatorService.new(product.id).duplicate
    expect(duplicate_product).not_to be(nil)
    expect(Link.where(name: "#{product.name} (copy)").count).to eq(1)
    expect(duplicate_product.preorder_link.release_at.to_date).to eq(1.month.from_now.to_date)
  end

  it "does not put membership tiers into an invalid state" do
    product_params = { user: seller, price_cents: 5000, name: "test product",
                       description: "description for test product",
                       is_recurring_billing: true, subscription_duration: "monthly",
                       is_in_preorder_state: true,
                       is_tiered_membership: true }
    product = create(:product, product_params)

    product.variant_categories.alive.first.variants.create!(name: "Second")

    duplicate_product = ProductDuplicatorService.new(product.id).duplicate

    expect(duplicate_product.is_tiered_membership).to eq true
    expect(duplicate_product.variant_categories.alive.size).to eq 1
    expect(duplicate_product.variant_categories.alive.first.variants.pluck(:name)).to eq ["Untitled", "Second"]
  end

  context "duplicating a collab product" do
    before { create(:collaborator, products: [product]) }

    it "does not mark a duplicated collab product as a collab" do
      expect(product.is_collab?).to eq true

      duplicate_product = ProductDuplicatorService.new(product.id).duplicate

      expect(duplicate_product.is_collab?).to eq false
    end
  end

  describe "prices" do
    it "handles products with rental prices" do
      product.is_recurring_billing = false
      product.purchase_type = "buy_and_rent"
      product.save!
      create(:price, link: product, price_cents: 300, is_rental: true)

      duplicate_product = ProductDuplicatorService.new(product.id).duplicate

      expect(duplicate_product.prices.size).to eq 2
      expect(duplicate_product.rental_price_cents).to eq 300
      expect(duplicate_product.buy_price_cents).to eq 5000
    end
  end

  describe "asset previews" do
    it "handles asset preview attachments for images" do
      asset_preview = AssetPreview.new(link: create(:product))
      asset_preview.file.attach(fixture_file_upload("test-small.jpg", "image/jpeg"))
      asset_preview.save!
      asset_preview.file.analyze

      duplicate_product = ProductDuplicatorService.new(asset_preview.link.id).duplicate

      expect(duplicate_product.asset_previews.count).to eq(1)
      expect(duplicate_product.asset_previews.first.file.attached?).to eq(true)
      expect(duplicate_product.asset_previews.first.file.analyzed?).to eq(true)
    end

    it "handles asset preview attachments for videos" do
      asset_preview = AssetPreview.new(link: create(:product))
      asset_preview.file.attach(fixture_file_upload("thing.mov", "video/quicktime"))
      asset_preview.save!
      asset_preview.file.analyze

      duplicate_product = ProductDuplicatorService.new(asset_preview.link.id).duplicate

      expect(duplicate_product.asset_previews.count).to eq(1)
      expect(duplicate_product.asset_previews.first.file.attached?).to eq(true)
      expect(duplicate_product.asset_previews.first.file.analyzed?).to eq(true)
    end

    it "ignores deleted asset previews" do
      asset_preview = AssetPreview.new(link: create(:product))
      asset_preview.file.attach(fixture_file_upload("test-small.jpg", "image/jpeg"))
      asset_preview.save!
      asset_preview.file.analyze
      asset_preview.mark_deleted

      duplicate_product = ProductDuplicatorService.new(asset_preview.link.id).duplicate

      expect(duplicate_product.asset_previews.count).to eq(0)
    end
  end

  describe "thumbnail" do
    it "handles duplication for an image attachment" do
      thumbnail = Thumbnail.new(product: create(:product))
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail.save!

      duplicate_product = ProductDuplicatorService.new(thumbnail.product.id).duplicate

      expect(duplicate_product.thumbnail).to_not eq(nil)
      expect(duplicate_product.thumbnail.file.attached?).to eq(true)
      expect(duplicate_product.thumbnail.file.analyzed?).to eq(true)
    end
  end

  describe "rich content" do
    it "duplicates the variant-level rich content ensuring the integrity of the file embeds" do
      product_file1 = create(:product_file, link: product)
      product_file2 = create(:readable_document, link: product)
      product_file3 = create(:listenable_audio, link: product)
      product_file4 = create(:streamable_video, link: product)
      category = create(:variant_category, link: product, title: "Versions")
      version1 = create(:variant, variant_category: category, name: "Version 1")
      version1.product_files << product_file1
      version2 = create(:variant, variant_category: category, name: "Version 2")
      version2.product_files << product_file2
      version2.product_files << product_file3
      version2.product_files << product_file4
      create(:rich_content, entity: version1, description: [
               { "type" => "paragraph", "content" => [{ "text" => "This is Version 1 content", "type" => "text" }] },
               { "type" => "fileEmbed", "attrs" => { "id" => product_file1.external_id, "uid" => "product-file-1-uid" } }
             ])
      create(:rich_content, entity: version2, description: [
               { "type" => "paragraph", "content" => [{ "text" => "This is Version 2 content", "type" => "text" }] },
               { "type" => "fileEmbed", "attrs" => { "id" => product_file2.external_id, "uid" => "product-file-2-uid" } },
               { "type" => "fileEmbedGroup",
                 "attrs" => { "uid" => "folder-uid", "name" => "Folder" },
                 "content" => [
                   { "type" => "fileEmbed", "attrs" => { "id" => product_file3.external_id, "uid" => "product-file-3-uid" } },
                   { "type" => "fileEmbed", "attrs" => { "id" => product_file4.external_id, "uid" => "product-file-4-uid" } }
                 ] }
             ])

      duplicate_product = ProductDuplicatorService.new(product.id).duplicate
      duplicate_product_files = duplicate_product.product_files.alive
      duplicate_product_file1 = duplicate_product_files.find_by(url: product_file1.url)
      duplicate_product_file2 = duplicate_product_files.find_by(url: product_file2.url)
      duplicate_product_file3 = duplicate_product_files.find_by(url: product_file3.url)
      duplicate_product_file4 = duplicate_product_files.find_by(url: product_file4.url)
      duplicate_product_version1 = duplicate_product.alive_variants.find_by(name: "Version 1")
      duplicate_product_version2 = duplicate_product.alive_variants.find_by(name: "Version 2")
      expect(duplicate_product_files.size).to eq(4)
      expect(duplicate_product.alive_variants.size).to eq(2)
      expect(duplicate_product_version1.product_files.alive).to eq([duplicate_product_file1])
      expect(duplicate_product_version2.product_files.alive).to eq([duplicate_product_file2, duplicate_product_file3, duplicate_product_file4])
      expect(duplicate_product_version1.alive_rich_contents.first.description).to eq(
        [
          { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "This is Version 1 content" }] },
          { "type" => "fileEmbed", "attrs" => { "id" => duplicate_product_file1.external_id, "uid" => "product-file-1-uid" } }
        ]
      )
      expect(duplicate_product_version2.alive_rich_contents.first.description).to eq(
        [
          { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "This is Version 2 content" }] },
          { "type" => "fileEmbed", "attrs" => { "id" => duplicate_product_file2.external_id, "uid" => "product-file-2-uid" } },
          { "type" => "fileEmbedGroup",
            "attrs" => { "uid" => "folder-uid", "name" => "Folder" },
            "content" => [
              { "type" => "fileEmbed", "attrs" => { "id" => duplicate_product_file3.external_id, "uid" => "product-file-3-uid" } },
              { "type" => "fileEmbed", "attrs" => { "id" => duplicate_product_file4.external_id, "uid" => "product-file-4-uid" } }
            ] }
        ]
      )
    end
  end

  describe "public files" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:public_file1) { create(:public_file, :with_audio, resource: product) }
    let(:public_file2) { create(:public_file, :with_audio, resource: product) }
    let(:description) do
      <<~HTML
        <p>Some text</p>
        <public-file-embed id="#{public_file1.public_id}"></public-file-embed>
        <p>Hello world!</p>
        <public-file-embed id="#{public_file2.public_id}"></public-file-embed>
        <p>More text</p>
      HTML
    end

    before do
      product.update!(description:)
    end

    it "duplicates public files and updates their embed IDs in the description" do
      duplicate_product = ProductDuplicatorService.new(product.id).duplicate

      expect(product.reload.description).to eq(description)
      expect(duplicate_product.public_files.count).to eq(2)
      duplicated_file1 = duplicate_product.public_files.alive.find_by(display_name: public_file1.display_name)
      duplicated_file2 = duplicate_product.public_files.alive.find_by(display_name: public_file2.display_name)
      expect(duplicated_file1.file).to be_attached
      expect(duplicated_file1.public_id).not_to eq(public_file1.public_id)
      expect(duplicated_file1.display_name).to eq(public_file1.display_name)
      expect(duplicated_file1.original_file_name).to eq(public_file1.original_file_name)
      expect(duplicated_file1.file_type).to eq(public_file1.file_type)
      expect(duplicated_file1.file_group).to eq(public_file1.file_group)
      expect(duplicated_file2.file).to be_attached
      expect(duplicated_file2.public_id).not_to eq(public_file2.public_id)
      expect(duplicated_file2.display_name).to eq(public_file2.display_name)
      expect(duplicated_file2.original_file_name).to eq(public_file2.original_file_name)
      expect(duplicated_file2.file_type).to eq(public_file2.file_type)
      expect(duplicated_file2.file_group).to eq(public_file2.file_group)
      expect(duplicate_product.description).to eq(description.gsub(public_file1.public_id, duplicated_file1.public_id).gsub(public_file2.public_id, duplicated_file2.public_id))
    end

    it "removes embeds for non-existent public files" do
      public_file1.mark_deleted!

      description_with_invalid_embeds = <<~HTML
        <p>Some text</p>
        <public-file-embed id="#{public_file1.public_id}"></public-file-embed>
        <p>Middle text</p>
        <public-file-embed id="#{public_file2.public_id}"></public-file-embed>
        <public-file-embed id="nonexistent"></public-file-embed>
        <public-file-embed></public-file-embed>
        <p>More text</p>
      HTML
      product.update!(description: description_with_invalid_embeds)

      duplicate_product = ProductDuplicatorService.new(product.id).duplicate

      duplicated_file = duplicate_product.public_files.alive.sole
      expect(duplicated_file.file).to be_attached
      expect(duplicated_file.file.blob).to eq(public_file2.file.blob)
      expect(duplicated_file.display_name).to eq(public_file2.display_name)
      expect(duplicate_product.description.scan(/<public-file-embed/).size).to eq(1)
      expect(duplicate_product.description).to include("<public-file-embed id=\"#{duplicated_file.public_id}\"></public-file-embed>")
    end
  end
end
