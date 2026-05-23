# frozen_string_literal: true

require "test_helper"

class BackfillPriceCheckerIndexFieldsJobTest < ActiveSupport::TestCase
  test "delegates to Onetime::BackfillPriceCheckerIndexFields.process" do
    called = false
    Onetime::BackfillPriceCheckerIndexFields.stub(:process, -> { called = true }) do
      BackfillPriceCheckerIndexFieldsJob.new.perform
    end
    assert called
  end
end
