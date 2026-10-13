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
  end
end
