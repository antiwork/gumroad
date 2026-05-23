# frozen_string_literal: true

require "test_helper"

class CommunityChatRecapTest < ActiveSupport::TestCase
  self.described_class = CommunityChatRecap



  context_ CommunityChatRecap do
    subject(:chat_recap) { build(:community_chat_recap) }

  context_ "associations" do
      it { is_expected.to belong_to(:community_chat_recap_run) }
      it { is_expected.to belong_to(:community).optional }
      it { is_expected.to belong_to(:seller).class_name("User").optional }
    end

  context_ "validations" do
      it { is_expected.to validate_presence_of(:summarized_message_count) }
      it { is_expected.to validate_numericality_of(:summarized_message_count).is_greater_than_or_equal_to(0) }
      it { is_expected.to validate_presence_of(:input_token_count) }
      it { is_expected.to validate_numericality_of(:input_token_count).is_greater_than_or_equal_to(0) }
      it { is_expected.to validate_presence_of(:output_token_count) }
      it { is_expected.to validate_numericality_of(:output_token_count).is_greater_than_or_equal_to(0) }

  context_ "seller presence" do
  context_ "when status is finished" do
          before do
            subject.status = "finished"
          end

          it { is_expected.to validate_presence_of(:seller) }
        end

  context_ "when status is not finished" do
          it { is_expected.not_to validate_presence_of(:seller) }
        end
      end

      it { is_expected.to define_enum_for(:status)
                            .with_values(pending: "pending", finished: "finished", failed: "failed")
                            .backed_by_column_of_type(:string)
                            .with_prefix(:status) }
    end
  end
end
