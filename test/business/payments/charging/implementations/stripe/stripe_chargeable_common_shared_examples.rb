# frozen_string_literal: true


shared_examples_for "stripe chargeable common" do
context_ "#charge_processor_id" do
test "returns 'stripe'" do
      expect(chargeable.charge_processor_id).to eq "stripe"
    end
  end
end
