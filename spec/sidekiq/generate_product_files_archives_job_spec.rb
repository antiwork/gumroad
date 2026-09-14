# frozen_string_literal: true

require "spec_helper"

describe GenerateProductFilesArchivesJob do
  let(:product) { create(:product) }

  it "rebuilds the product's archives under the row lock" do
    expect(Link).to receive(:find_by).with(id: product.id).and_return(product)
    expect(product).to receive(:with_lock).and_yield
    expect(product).to receive(:generate_product_files_archives!)

    described_class.new.perform(product.id)
  end

  it "skips deleted and missing products" do
    product.mark_deleted!
    expect_any_instance_of(Link).not_to receive(:generate_product_files_archives!)

    described_class.new.perform(product.id)
    described_class.new.perform(-1)
  end
end
