# frozen_string_literal: true


shared_examples_for "MaxPurchaseCount concern" do |factory_name|
test "automatically constrains the max_purchase_count" do
    object = create(factory_name)
    object.update!(max_purchase_count: 999_999_999_999)
    expect(object.max_purchase_count).to eq(10_000_000)
    object.update!(max_purchase_count: -100)
    expect(object.max_purchase_count).to eq(0)
  end
end
