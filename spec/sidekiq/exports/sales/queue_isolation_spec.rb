# frozen_string_literal: true

require "spec_helper"

describe "Sales export queue isolation" do
  [
    Exports::Sales::CreateAndEnqueueChunksWorker,
    Exports::Sales::ProcessChunkWorker,
    Exports::Sales::CompileChunksWorker,
  ].each do |worker|
    it "runs #{worker} on the dedicated exports queue, not the shared low queue" do
      expect(worker.sidekiq_options["queue"].to_s).to eq("exports")
    end
  end

  it "enqueues every chunk on the exports queue so a big export cannot fill low" do
    chunk_ids = [1, 2, 3]
    Exports::Sales::ProcessChunkWorker.perform_bulk(chunk_ids.map { |id| [id] })

    expect(Sidekiq::Queues["exports"].size).to eq(3)
    expect(Sidekiq::Queues["low"]).to be_empty
  end

  it "has sidekiq workers read the exports queue, otherwise exports would never run" do
    %w[docker/web/sidekiq_worker.sh Procfile.dev Procfile.debug].each do |path|
      content = Rails.root.join(path).read
      expect(content).to match(/-q exports/), "#{path} must list -q exports"
      expect(content).to match(/-q low/)
      # exports comes after low so it only uses idle threads.
      expect(content.index("-q low")).to be < content.index("-q exports"), "#{path} must list -q exports after -q low"
    end
  end
end
