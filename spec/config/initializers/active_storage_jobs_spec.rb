# frozen_string_literal: true

require "spec_helper"

describe "ActiveStorage::AnalyzeJob error handling" do
  it "discards the job when S3 returns NoSuchKey" do
    expect(ActiveStorage::AnalyzeJob.rescue_handlers).to include(
      satisfy { |handler| handler[0] == "Aws::S3::Errors::NoSuchKey" }
    )
  end
end

describe "ActiveStorage::PreviewImageJob error handling" do
  it "discards the job when the previewer raises ActiveStorage::PreviewError" do
    expect(ActiveStorage::PreviewImageJob.rescue_handlers).to include(
      satisfy { |handler| handler[0] == "ActiveStorage::PreviewError" }
    )
  end

  it "does not re-raise and logs a warning when PreviewError is raised" do
    allow_any_instance_of(ActiveStorage::PreviewImageJob).to receive(:perform)
      .and_raise(ActiveStorage::PreviewError, "ffmpeg failed (status 1): could not decode input")
    allow(Rails.logger).to receive(:warn)

    expect do
      ActiveStorage::PreviewImageJob.perform_now("fake_blob", [])
    end.not_to raise_error

    expect(Rails.logger).to have_received(:warn)
      .with(a_string_including("Discarding PreviewImageJob").and(a_string_including("ffmpeg failed")))
  end
end
