# frozen_string_literal: true

require "test_helper"

class ConfigInitializersActiveStorageJobsTest < ActiveSupport::TestCase



  context_ "ActiveStorage::AnalyzeJob error handling" do
  test "discards the job when S3 returns NoSuchKey" do
      expect(ActiveStorage::AnalyzeJob.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Aws::S3::Errors::NoSuchKey" }
      )
    end
  end
end
