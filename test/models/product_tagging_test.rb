# frozen_string_literal: true

require "test_helper"

class ProductTaggingTest < ActiveSupport::TestCase
  self.described_class = ProductTagging



  context_ ProductTagging do
    before do
      @creator = create(:user)
      product_a = create(:product)
      product_a.tag!("tag a")
      product_a.tag!("tag b")
      product_a.tag!("tag c")

      product_b = create(:product, user: @creator)
      product_b.tag!("tag b")
      product_b.tag!("tag c")

      product_c = create(:product)
      product_c.tag!("tag b")
    end

  context_ ".sorted_by_tags_usage_for_products" do
  test "returns tags sorted by number of tagged products" do
        product_taggings = ProductTagging.sorted_by_tags_usage_for_products(Link.all)
        expect(product_taggings.to_a.map(&:tag).map(&:name)).to eq([
                                                                     "tag b",
                                                                     "tag c",
                                                                     "tag a",
                                                                   ])
      end
    end

  context_ ".owned_by_user" do
  test "returns tags owned by a user" do
        product_tagging = ProductTagging.owned_by_user(@creator)
        expect(product_tagging.first.tag.name).to eq("tag b")
      end
    end

  context_ ".has_tag_name" do
  test "returns tags by name" do
        product_tagging = ProductTagging.has_tag_name("tag b")
        expect(product_tagging.first.tag.name).to eq("tag b")
      end
    end
  end
end
