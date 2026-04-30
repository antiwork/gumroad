# frozen_string_literal: true

require "spec_helper"

describe "ActiveStorage::AnalyzeJob error handling" do
  it "discards the job when S3 returns NoSuchKey" do
    expect(ActiveStorage::AnalyzeJob.rescue_handlers).to include(
      satisfy { |handler| handler[0] == "Aws::S3::Errors::NoSuchKey" }
    )
  end
end
