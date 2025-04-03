# frozen_string_literal: true

require "spec_helper"

describe InstallmentRule do
  describe "version" do
    before do
      @product = create(:product)
      @post = create(:installment, link: @product, installment_type: "product")
      @post_rule = create(:installment_rule, installment: @post, to_be_published_at: 1.week.from_now)
    end

    it "has the installment_rule starting version be 1" do
      expect(@post_rule.reload.version).to eq(1)
    end

    it "increments the version when to_be_published_at changes" do
      expect do
        @post_rule.update(to_be_published_at: 1.month.from_now)
      end.to change { @post_rule.reload.version }.by(1)
      expect(@post_rule.reload.version).to eq(2)
    end

    it "increments the version if delayed_delivery_time is changed" do
      expect do
        @post_rule.delayed_delivery_time = 100
        @post_rule.save
      end.to change { @post_rule.reload.version }.by(1)
      expect(@post_rule.reload.version).to eq(2)
    end

    it "does not increment the version if period is changed" do
      expect do
        @post_rule.time_period = "DAY"
        @post_rule.save
      end.to_not change { @post_rule.reload.version }
    end

    it "does not increment the version if period is changed" do
      expect do
        @post_rule.time_period = "DAY"
        @post_rule.save
      end.to_not change { @post_rule.reload.version }
    end
  end

  describe "displayable_time_duration" do
    before do
      @product = create(:product)
      @post = create(:installment, link: @product, installment_type: "product")
      @post_rule = create(:installment_rule, installment: @post, delayed_delivery_time: 1.week, time_period: "week")
    end

    it "returns the correct duration based on the time period" do
      expect(@post_rule.displayable_time_duration).to eq(1)
      @post_rule.update(delayed_delivery_time: 2.weeks, time_period: "day")
      expect(@post_rule.displayable_time_duration).to eq(14)
      @post_rule.update(delayed_delivery_time: 2.hours, time_period: "hour")
      expect(@post_rule.displayable_time_duration).to eq(2)
      @post_rule.update(delayed_delivery_time: 1.month, time_period: "month")
      expect(@post_rule.displayable_time_duration).to eq(1)
    end
  end

  describe "validations" do
    describe "to_be_published_at_cannot_be_in_the_past" do
      before do
        post = create(:post, workflow: create(:audience_workflow))
        @post_rule = create(:installment_rule, to_be_published_at: nil, installment: post)
      end

      it "allows to_be_published_at to be nil" do
        expect(@post_rule.to_be_published_at).to be_nil
        expect(@post_rule).to be_valid
      end

      it "disallows to_be_published_at to be in the past" do
        @post_rule.to_be_published_at = Time.current
        expect(@post_rule).not_to be_valid
        expect(@post_rule.errors.full_messages).to include("Please select a date and time in the future.")
      end

      context "when about to be marked as deleted" do
        it "allows to_be_published_at to be in the past" do
          @post_rule.to_be_published_at = Time.current
          @post_rule.deleted_at = Time.current
          expect(@post_rule).to be_valid
        end
      end
    end

    describe "to_be_published_at_must_exist_for_non_workflow_posts" do
      it "disallows to_be_published_at to be nil" do
        post_rule = build(:installment_rule, to_be_published_at: nil)
        expect(post_rule).not_to be_valid
        expect(post_rule.errors.full_messages).to include("Please select a date and time in the future.")
      end
    end
  end
end
