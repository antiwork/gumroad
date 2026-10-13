# frozen_string_literal: true

require "spec_helper"

describe Product::Tags do
  before do
    @product = create(:product)
    @alpha = create(:tag, name: "alpha")
    @beta = create(:tag, name: "beta")
    @gamma = create(:tag, name: "gamma")
  end

  describe "#save_tags!" do
    it "saves the given tag list" do
      @product.save_tags!(["gamma", "beta"])

      expect(@product.reload.tags.pluck(:name)).to contain_exactly("beta", "gamma")
    end

    it "removes tags that are no longer in the list" do
      @product.save_tags!(["alpha", "beta"])
      @product.save_tags!(["beta"])

      expect(@product.reload.tags.pluck(:name)).to contain_exactly("beta")
    end

    it "takes the tags rows in tag-id order, not the caller's order" do
      expect(@product).to receive(:tag!).with("alpha").ordered
      expect(@product).to receive(:tag!).with("gamma").ordered

      @product.save_tags!(["gamma", "alpha"])
    end

    it "interleaves removals and additions, so swapping two tags cannot invert the lock order" do
      @product.save_tags!(["beta"])

      expect(@product).to receive(:tag!).with("alpha").ordered
      expect(@product).to receive(:untag!).with("beta").ordered

      @product.save_tags!(["alpha"])
    end

    it "removes before it adds when both spellings resolve to the same tag row" do
      @product.save_tags!(["alpha"])

      expect(@product).to receive(:untag!).with("alpha").ordered
      expect(@product).to receive(:tag!).with("ALPHA").ordered

      @product.save_tags!(["ALPHA"])
    end

    it "accepts an existing tag re-spelled in a different case" do
      @product.save_tags!(["alpha"])

      expect { @product.save_tags!(["ALPHA"]) }.not_to raise_error
      expect(@product.reload.tags.pluck(:name)).to eq(["alpha"])
    end

    it "orders by the tag row a name resolves to, not the spelling" do
      accented = create(:tag, name: "café")
      plain = create(:tag, name: "zeta")
      @product.save_tags!([plain.name])

      expect(Tag.find_by(name: "cafe")).to eq(accented)
      expect(@product).to receive(:tag!).with("cafe").ordered
      expect(@product).to receive(:untag!).with("zeta").ordered

      @product.save_tags!(["cafe"])
    end
  end

  describe "#product_taggings" do
    it "traverses the taggings in tag-id order, so every writer locks the same rows in the same order" do
      ProductTagging.create!(product: @product, tag: @gamma)
      ProductTagging.create!(product: @product, tag: @alpha)
      ProductTagging.create!(product: @product, tag: @beta)

      expect(@product.product_taggings.map(&:tag_id)).to eq([@alpha.id, @beta.id, @gamma.id])
    end
  end
end
