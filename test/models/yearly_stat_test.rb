# frozen_string_literal: true

require "test_helper"

class YearlyStatTest < ActiveSupport::TestCase
  self.described_class = YearlyStat



  context_ YearlyStat do
  context_ "associations" do
      it { is_expected.to belong_to(:user) }
    end
  end
end
