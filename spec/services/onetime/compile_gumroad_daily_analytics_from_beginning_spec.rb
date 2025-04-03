# frozen_string_literal: true

require "spec_helper"

describe Onetime::CompileGumroadDailyAnalyticsFromBeginning do
  it "compiles analytics from the start of Gumroad" do
    stub_const("GUMROAD_STARTED_DATE", Date.parse("2023-01-01"))
    allow(Date).to receive(:today).and_return(Date.new(2023, 1, 15))

    expect(GumroadDailyAnalytic).to receive(:import).exactly(15).times.and_call_original
    Onetime::CompileGumroadDailyAnalyticsFromBeginning.process

    expect(GumroadDailyAnalytic.all.size).to eq(15)
  end
end
