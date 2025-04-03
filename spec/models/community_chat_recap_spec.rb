# frozen_string_literal: true

require "spec_helper"

RSpec.describe CommunityChatRecap do
  subject(:chat_recap) { build(:community_chat_recap) }

  describe "associations" do
    it { is_expected.to belong_to(:community_chat_recap_run) }
    it { is_expected.to belong_to(:community).optional }
    it { is_expected.to belong_to(:seller).class_name("User").optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:summarized_message_count) }
    it { is_expected.to validate_numericality_of(:summarized_message_count).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_presence_of(:input_token_count) }
    it { is_expected.to validate_numericality_of(:input_token_count).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_presence_of(:output_token_count) }
    it { is_expected.to validate_numericality_of(:output_token_count).is_greater_than_or_equal_to(0) }

    describe "seller presence" do
      context "when status is finished" do
        before do
          subject.status = "finished"
        end

        it { is_expected.to validate_presence_of(:seller) }
      end

      context "when status is not finished" do
        it { is_expected.not_to validate_presence_of(:seller) }
      end
    end

    it { is_expected.to define_enum_for(:status)
                          .with_values(pending: "pending", finished: "finished", failed: "failed")
                          .backed_by_column_of_type(:string)
                          .with_prefix(:status) }
  end
end
