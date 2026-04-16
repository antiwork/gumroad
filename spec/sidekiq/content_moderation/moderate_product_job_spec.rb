# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::ModerateProductJob do
  describe "#perform" do
    it "finds the product and delegates to the moderation service" do
      product = create(:product)
      service = instance_double(ContentModeration::ModerateRecordService, perform: true)

      expect(ContentModeration::ModerateRecordService).to receive(:new).with(product, :product).and_return(service)

      described_class.new.perform(product.id)
    end
  end
end
