# frozen_string_literal: true

require "test_helper"

class DuplicateProductWorkerTest < ActiveSupport::TestCase
  self.described_class = DuplicateProductWorker



  context_ DuplicateProductWorker do
  context_ "#perform" do
      before do
        @product = create(:product, name: "test product")
      end

  test "duplicates product successfully" do
        expect { described_class.new.perform(@product.id) }.to change(Link, :count).by(1)

        expect(Link.exists?(name: "test product (copy)")).to be(true)
      end

  test "sets product is_duplicating to false" do
        @product.update!(is_duplicating: true)

        expect { described_class.new.perform(@product.id) }.to change(Link, :count).by(1)

        expect(@product.reload.is_duplicating).to be(false)
      end

  test "sets product is_duplicating to false on failure" do
        @product.update!(is_duplicating: true)

        expect_any_instance_of(ProductDuplicatorService).to receive(:duplicate).and_raise(StandardError)

        expect { described_class.new.perform(@product.id) }.not_to change(Link, :count)

        expect(@product.reload.is_duplicating).to be(false)
      end

  test "logs and notifies error tracker on failure" do
        error = StandardError.new("Something broke")
        expect_any_instance_of(ProductDuplicatorService).to receive(:duplicate).and_raise(error)

        expect(ErrorNotifier).to receive(:notify).with(error)

        described_class.new.perform(@product.id)
      end
    end
  end
end
