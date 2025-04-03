# frozen_string_literal: true

describe CallLimitationInfo do
  describe "validations" do
    context "call is not a call product" do
      let(:call_limitation_info) { build(:call_limitation_info, call: create(:product)) }

      it "adds an error" do
        expect(call_limitation_info).not_to be_valid
        expect(call_limitation_info.errors.full_messages).to eq(["Cannot create call limitations for a non-call product."])
      end
    end
  end

  describe "#can_take_more_calls_on?" do
    let(:call_product) { create(:call_product, :available_for_a_year) }
    let(:call_limitation_info) { call_product.call_limitation_info }
    let(:tomorrow_noon) { Time.current.in_time_zone(call_product.user.timezone).tomorrow.noon }

    context "when maximum_calls_per_day is not set" do
      before { call_limitation_info.update!(maximum_calls_per_day: nil) }

      it "returns true" do
        expect(call_limitation_info.can_take_more_calls_on?(tomorrow_noon)).to be true
      end
    end

    context "when maximum_calls_per_day is set" do
      before { call_limitation_info.update!(maximum_calls_per_day: 2, minimum_notice_in_minutes: nil) }

      it "returns true when the number of calls is less than the maximum on that date" do
        create(:call, start_time: tomorrow_noon, end_time: tomorrow_noon + 1.hour, link: call_product)
        expect(call_limitation_info.can_take_more_calls_on?(tomorrow_noon)).to be true

        create(:call, start_time: tomorrow_noon + 1.hour, end_time: tomorrow_noon + 2.hours, link: call_product)
        expect(call_limitation_info.can_take_more_calls_on?(tomorrow_noon)).to be false
        expect(call_limitation_info.can_take_more_calls_on?(tomorrow_noon.next_day)).to be true
      end
    end
  end

  describe "#has_enough_notice?", :freeze_time do
    let(:call_product) { create(:call_product, :available_for_a_year) }
    let(:call_limitation_info) { call_product.call_limitation_info }

    context "when minimum_notice_in_minutes is set" do
      let(:notice_period) { 2.hours }

      before { call_limitation_info.update!(minimum_notice_in_minutes: notice_period.in_minutes) }

      it "returns false when start time is before the minimum notice period" do
        expect(call_limitation_info.has_enough_notice?(notice_period.from_now)).to be true
        expect(call_limitation_info.has_enough_notice?(notice_period.from_now + 1.minute)).to be true

        with_in_grace_period = notice_period.from_now - CallLimitationInfo::CHECKOUT_GRACE_PERIOD
        expect(call_limitation_info.has_enough_notice?(with_in_grace_period)).to be true
        expect(call_limitation_info.has_enough_notice?(with_in_grace_period - 1.minute)).to be false
      end
    end

    context "when minimum_notice_in_minutes is not set" do
      before { call_limitation_info.update!(minimum_notice_in_minutes: nil) }

      it "returns false if start time is in the past" do
        expect(call_limitation_info.has_enough_notice?(1.minute.ago)).to be false
        expect(call_limitation_info.has_enough_notice?(1.minute.from_now)).to be true
      end
    end
  end

  describe "#allows?" do
    let(:call_product) { create(:call_product, :available_for_a_year) }
    let(:call_limitation_info) { call_product.call_limitation_info }

    it "returns true iff has enough notice and can take more calls" do
      start_time = 1.day.from_now

      allow(call_limitation_info).to receive(:has_enough_notice?).with(start_time).and_return(false)
      allow(call_limitation_info).to receive(:can_take_more_calls_on?).with(start_time).and_return(false)

      expect(call_limitation_info.allows?(start_time)).to be false

      allow(call_limitation_info).to receive(:has_enough_notice?).with(start_time).and_return(true)
      expect(call_limitation_info.allows?(start_time)).to be false

      allow(call_limitation_info).to receive(:can_take_more_calls_on?).with(start_time).and_return(true)
      expect(call_limitation_info.allows?(start_time)).to be true
    end
  end
end
