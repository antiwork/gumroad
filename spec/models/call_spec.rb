# frozen_string_literal: true

require "sidekiq/testing"

describe Call do
  let(:link) { create(:call_product, :available_for_a_year) }
  let(:call_limitation_info) { link.call_limitation_info }

  describe "normalizations", :freeze_time do
    before { travel_to(DateTime.parse("May 1 2024 UTC")) }

    it "drops sub-minute precision from start_time and end_time when assigning" do
      call = build(
        :call,
        start_time: DateTime.parse("May 8 2024 10:28:01.123456 UTC"),
        end_time: DateTime.parse("May 9 2024 11:29:59.923456 UTC"),
        link:
      )
      expect(call.start_time).to eq(DateTime.parse("May 8 2024 10:28 UTC"))
      expect(call.end_time).to eq(DateTime.parse("May 9 2024 11:29 UTC"))
    end

    it "drops sub-minute precision from start_time and end_time when querying" do
      call = create(
        :call,
        start_time: DateTime.parse("May 8 2024 10:28:01.123456 UTC"),
        end_time: DateTime.parse("May 9 2024 11:29:59.923456 UTC"),
        link:
      )
      expect(Call.find_by(start_time: call.start_time.change(sec: 2))).to eq(call)
      expect(Call.find_by(end_time: call.end_time.change(sec: 58))).to eq(call)
    end
  end

  describe "validations" do
    it "validates that start_time is before end_time" do
      call = build(:call, start_time: 2.days.from_now, end_time: 1.day.from_now)
      expect(call).to be_invalid
      expect(call.errors.full_messages).to include("Start time must be before end time.")
    end

    it "validates that start_time and end_time are present" do
      call = build(:call, start_time: nil, end_time: nil)
      expect(call).to be_invalid
      expect(call.errors.full_messages).to include("Start time can't be blank", "End time can't be blank")
    end

    it "validates that the purchased product is a call" do
      call = build(:call, purchase: create(:physical_purchase))
      expect(call).to be_invalid
      expect(call.errors.full_messages).to include("Purchased product must be a call")
    end

    it "validates that the selected time is allowed by #call_limitation_info" do
      call = build(:call, link:)

      allow(call_limitation_info).to receive(:allows?).with(call.start_time).and_return(false)
      expect(call).to be_invalid
      expect(call.errors.full_messages).to include("Selected time is no longer available")

      allow(call_limitation_info).to receive(:allows?).with(call.start_time).and_return(true)
      expect(call).to be_valid
    end

    it "validates that the selected time is available and not yet taken" do
      call = build(:call, link:)

      link.call_availabilities.destroy_all
      expect(call).to be_invalid
      expect(call.errors.full_messages).to include("Selected time is no longer available")

      create(:call_availability, start_time: call.start_time, end_time: call.end_time, call: link)
      expect(call).to be_valid

      create(:call, start_time: call.start_time, end_time: call.end_time, purchase: build(:call_purchase, :refunded, link:))
      expect(call).to be_valid

      create(:call, start_time: call.start_time, end_time: call.end_time, link:)
      expect(call).to be_invalid
      expect(call.errors.full_messages).to include("Selected time is no longer available")
    end

    it "does not validate selected time availability for gift receiver purchases" do
      start_time = 1.day.from_now
      end_time = start_time + 1.hour
      create(:call, start_time:, end_time:, link:)

      call = build(:call, start_time:, end_time:, link:)
      expect(call).to be_invalid
      expect(call.errors.full_messages).to include("Selected time is no longer available")

      call.purchase.is_gift_receiver_purchase = true
      expect(call).to be_valid
    end
  end

  describe "scopes", :freeze_time do
    before { travel_to(DateTime.parse("May 1 2024 UTC")) }

    let(:time_1) { 1.day.from_now }
    let(:time_2) { 2.days.from_now }
    let(:time_3) { 3.days.from_now }
    let(:time_4) { 4.days.from_now }

    describe ".occupies_availability" do
      let!(:refunded) { create(:call_purchase, :refunded, link:) }
      let!(:failed) { create(:call_purchase, purchase_state: "failed", link:) }
      let!(:test_successful) { create(:call_purchase, purchase_state: "test_successful", link:) }
      let!(:gift_receiver_purchase_successful) { create(:call_purchase, purchase_state: "gift_receiver_purchase_successful", link:) }

      let!(:successful) { create(:call_purchase, purchase_state: "successful") }
      let!(:not_charged) { create(:call_purchase, purchase_state: "not_charged") }
      let!(:in_progress) { create(:call_purchase, purchase_state: "in_progress") }

      it "returns calls that take up availability" do
        expect(Call.occupies_availability).to contain_exactly(successful.call, not_charged.call, in_progress.call)
      end
    end

    describe ".upcoming" do
      let!(:not_started) { create(:call, :skip_validation, start_time: 2.days.from_now, end_time: 3.days.from_now, link:) }
      let!(:started_but_not_ended) { create(:call, :skip_validation, start_time: 2.days.ago, end_time: 1.day.from_now, link:) }
      let!(:ended) { create(:call, :skip_validation, start_time: 2.days.ago, end_time: 1.day.ago, link:) }

      it "returns calls that haven't ended" do
        expect(Call.upcoming).to contain_exactly(not_started, started_but_not_ended)
      end
    end

    describe ".ordered_chronologically" do
      let!(:call_2_to_3) { create(:call, start_time: time_2, end_time: time_3, link:) }
      let!(:call_1_to_3) { create(:call, start_time: time_1, end_time: time_3) }
      let!(:call_1_to_2) { create(:call, start_time: time_1, end_time: time_2, link:) }

      it "returns calls ordered chronologically" do
        expect(Call.ordered_chronologically.pluck(:id)).to eq([call_1_to_2.id, call_1_to_3.id, call_2_to_3.id])
      end
    end

    describe ".starts_on_date" do
      let(:pt) { ActiveSupport::TimeZone.new("Pacific Time (US & Canada)") }
      let(:et) { ActiveSupport::TimeZone.new("Eastern Time (US & Canada)") }

      let(:tomorrow_8_pm_pt) { pt.now.next_day.change(hour: 20) }
      let(:tomorrow_10_pm_pt) { pt.now.next_day.change(hour: 22) }

      let!(:call_tomorrow_8_pm_pt) { create(:call, start_time: tomorrow_8_pm_pt, end_time: tomorrow_8_pm_pt + 1.hour, link:) }
      let!(:call_tomorrow_10_pm_pt) { create(:call, start_time: tomorrow_10_pm_pt, end_time: tomorrow_10_pm_pt + 1.hour, link:) }

      it "returns calls that start on the given time's date in the given time zone" do
        expect(Call.starts_on_date(tomorrow_8_pm_pt, pt)).to contain_exactly(call_tomorrow_8_pm_pt, call_tomorrow_10_pm_pt)
        expect(Call.starts_on_date(tomorrow_8_pm_pt, et)).to contain_exactly(call_tomorrow_8_pm_pt)
      end
    end

    describe ".overlaps_with" do
      let!(:call_1_to_2) { create(:call, start_time: time_1, end_time: time_2, link:) }
      let!(:call_3_to_4) { create(:call, start_time: time_3, end_time: time_4, link:) }

      it "returns calls that overlap with the given time range" do
        expect(Call.overlaps_with(time_1, time_2)).to contain_exactly(call_1_to_2)
        expect(Call.overlaps_with(time_1, time_3)).to contain_exactly(call_1_to_2)
        expect(Call.overlaps_with(time_1, time_4)).to contain_exactly(call_1_to_2, call_3_to_4)
        expect(Call.overlaps_with(time_2, time_3)).to be_empty
        expect(Call.overlaps_with(time_2, time_4)).to contain_exactly(call_3_to_4)
      end
    end
  end


  describe "#formatted_time_range" do
    let(:call) { create(:call, :skip_validation, start_time: DateTime.parse("January 1 2024 10:00"), end_time: DateTime.parse("January 1 2024 11:00")) }

    it "returns the formatted time range" do
      expect(call.formatted_time_range).to eq("02:00 AM - 03:00 AM PST")
    end
  end

  describe "#formatted_date_range" do
    context "when start and end times are on the same day" do
      let(:call) { create(:call, :skip_validation, start_time: DateTime.parse("January 1 2024 10:00"), end_time: DateTime.parse("January 1 2024 11:00")) }

      it "returns the formatted date" do
        expect(call.formatted_date_range).to eq("Monday, January 1st, 2024")
      end
    end

    context "when start and end times are on different days" do
      let(:call) { create(:call, :skip_validation, start_time: DateTime.parse("January 1 2024"), end_time: DateTime.parse("January 2 2024")) }

      it "returns the formatted date range" do
        expect(call.formatted_date_range).to eq("Sunday, December 31st, 2023 - Monday, January 1st, 2024")
      end
    end
  end

  describe "#eligible_for_reminder?" do
    context "when the purchase is in progress" do
      let(:purchase) { create(:call_purchase, purchase_state: "in_progress") }
      let(:call) { purchase.call }

      it "returns true" do
        expect(call.eligible_for_reminder?).to be true
      end
    end

    context "when the purchase is a gift sender purchase" do
      let(:purchase) { create(:call_purchase, is_gift_sender_purchase: true) }
      let(:call) { purchase.call }

      it "returns false" do
        expect(call.eligible_for_reminder?).to be false
      end
    end

    context "when the purchase has been refunded" do
      let(:purchase) { create(:call_purchase, :refunded) }
      let(:call) { purchase.call }

      it "returns false" do
        expect(call.eligible_for_reminder?).to be false
      end
    end

    context "when the purchase failed" do
      let(:purchase) { create(:call_purchase, purchase_state: "failed") }
      let(:call) { purchase.call }

      it "returns false" do
        expect(call.eligible_for_reminder?).to be false
      end
    end

    context "when the purchase is a gift receiver purchase" do
      let(:product) { create(:call_product, :available_for_a_year, name: "Portfolio review") }
      let(:variant_category) { product.variant_categories.first }
      let(:variant) { create(:variant, name: "60 minutes", duration_in_minutes: 60, variant_category:) }
      let(:gifter_purchase) { create(:call_purchase, link: product, variant_attributes: [variant]) }
      let(:giftee_purchase) { create(:call_purchase, :gift_receiver, link: product, variant_attributes: [variant]) }
      let!(:gift) { create(:gift, gifter_purchase:, giftee_purchase:) }
      let(:call) { giftee_purchase.call }

      it "returns true" do
        expect(call.eligible_for_reminder?).to be true
      end
    end

    context "when the purchase is successful" do
      let(:purchase) { create(:call_purchase, purchase_state: "successful") }
      let(:call) { purchase.call }

      it "returns true" do
        expect(call.eligible_for_reminder?).to be true
      end
    end
  end

  describe "scheduling reminder emails" do
    context "when the call is less than 24 hours away" do
      let(:start_time) { 23.hours.from_now }
      let(:end_time) { start_time + 1.hour }
      let(:call) { build(:call, start_time:, end_time:, link:) }

      it "does not schedule reminder emails" do
        expect do
          call.save!
        end.to not_have_enqueued_mail(ContactingCreatorMailer, :upcoming_call_reminder)
          .and not_have_enqueued_mail(CustomerMailer, :upcoming_call_reminder)
      end
    end

    context "when the call is more than 24 hours away" do
      let(:start_time) { 25.hours.from_now }
      let(:end_time) { start_time + 1.hour }
      let(:call) { build(:call, start_time:, end_time:, link:) }

      it "schedules reminder emails" do
        expect do
          call.save!
        end.to have_enqueued_mail(ContactingCreatorMailer, :upcoming_call_reminder)
          .and have_enqueued_mail(CustomerMailer, :upcoming_call_reminder)
      end
    end

    context "when the call is for a gift sender purchase" do
      let(:start_time) { 25.hours.from_now }
      let(:end_time) { start_time + 1.hour }
      let(:call) { build(:call, start_time:, end_time:, purchase: create(:call_purchase, is_gift_sender_purchase: true)) }

      it "does not schedule reminder emails" do
        expect do
          call.save!
        end.to not_have_enqueued_mail(ContactingCreatorMailer, :upcoming_call_reminder)
          .and not_have_enqueued_mail(CustomerMailer, :upcoming_call_reminder)
      end
    end
  end

  describe "google calendar integration" do
    let(:integration) { create(:google_calendar_integration) }
    let(:call) { create(:call, link: create(:call_product, :available_for_a_year, active_integrations: [integration])) }
    let(:call2) { create(:call, link: create(:call_product, :available_for_a_year)) }

    it "schedules google calendar invites" do
      expect do
        call.save!
      end.to change(GoogleCalendarInviteJob.jobs, :size).by(1)

      expect(GoogleCalendarInviteJob.jobs.last["args"]).to eq([call.id])
    end

    it "does not schedule google calendar invites if the call is not linked to a google calendar integration" do
      expect do
        call2.save!
      end.to change(GoogleCalendarInviteJob.jobs, :size).by(0)
    end
  end
end
