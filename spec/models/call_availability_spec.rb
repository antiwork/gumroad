# frozen_string_literal: true

describe CallAvailability do
  describe "normalizations" do
    it "drops sub-minute precision from start_time and end_time when assigning" do
      call_availability = build(
        :call_availability,
        start_time: DateTime.parse("May 1 2024 10:28:01.123456 UTC"),
        end_time: DateTime.parse("May 1 2024 11:29:59.923456 UTC")
      )

      expect(call_availability.start_time).to eq(DateTime.parse("May 1 2024 10:28:00 UTC"))
      expect(call_availability.end_time).to eq(DateTime.parse("May 1 2024 11:29:00 UTC"))
    end

    it "drops sub-minute precision from start_time and end_time when querying" do
      call_availability = create(
        :call_availability,
        start_time: DateTime.parse("May 1 2024 10:28:01.123456 UTC"),
        end_time: DateTime.parse("May 1 2024 11:29:59.923456 UTC")
      )

      expect(CallAvailability.find_by(start_time: call_availability.start_time.change(sec: 2))).to eq(call_availability)
      expect(CallAvailability.find_by(end_time: call_availability.end_time.change(sec: 58))).to eq(call_availability)
    end
  end

  describe "validations" do
    let!(:call_availability) { build(:call_availability) }

    context "end time is before start time" do
      it "adds an error" do
        call_availability.end_time = call_availability.start_time - 1.hour

        expect(call_availability).not_to be_valid
        expect(call_availability.errors.full_messages).to eq(["Start time must be before end time."])
      end
    end
  end

  describe "scopes", :freeze_time do
    let!(:not_started) { create(:call_availability, start_time: 1.day.from_now, end_time: 2.days.from_now) }
    let!(:started_but_not_ended) { create(:call_availability, start_time: 2.days.ago, end_time: 2.day.from_now) }
    let!(:ended) { create(:call_availability, start_time: 2.days.ago, end_time: 1.day.ago) }

    describe ".upcoming" do
      it "returns call availabilities that hasn't ended" do
        expect(CallAvailability.upcoming).to contain_exactly(started_but_not_ended, not_started)
      end
    end

    describe ".ordered_chronologically" do
      it "orders by start time and end time" do
        expect(CallAvailability.ordered_chronologically.pluck(:id)).to eq(
          [ended.id, started_but_not_ended.id, not_started.id]
        )
      end
    end

    describe ".containing" do
      it "returns call availabilities that strictly contain the given time range" do
        expect(CallAvailability.containing(not_started.start_time, not_started.end_time))
          .to contain_exactly(not_started, started_but_not_ended)
        expect(CallAvailability.containing(not_started.start_time - 1.second, not_started.end_time))
          .to contain_exactly(started_but_not_ended)
        expect(CallAvailability.containing(not_started.start_time, not_started.end_time + 1.second))
          .to be_empty
      end
    end
  end
end
