# frozen_string_literal: true

require "spec_helper"

describe ProductTagging do
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

  describe ".sorted_by_tags_usage_for_products" do
    it "returns tags sorted by number of tagged products" do
      product_taggings = ProductTagging.sorted_by_tags_usage_for_products(Link.all)
      expect(product_taggings.to_a.map(&:tag).map(&:name)).to eq([
                                                                   "tag b",
                                                                   "tag c",
                                                                   "tag a",
                                                                 ])
    end
  end

  describe ".owned_by_user" do
    it "returns tags owned by a user" do
      product_tagging = ProductTagging.owned_by_user(@creator)
      expect(product_tagging.first.tag.name).to eq("tag b")
    end
  end

  describe ".has_tag_name" do
    it "returns tags by name" do
      product_tagging = ProductTagging.has_tag_name("tag b")
      expect(product_tagging.first.tag.name).to eq("tag b")
    end
  end
end
