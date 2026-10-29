# frozen_string_literal: true

require "spec_helper"

describe "Sidekiq job on_conflict strategies" do
  # Read from the options Sidekiq applies at enqueue, not from source text, so a multiline or
  # string-keyed declaration can't slip past. Classes defined in specs are left out.
  let(:job_classes) do
    Rails.application.eager_load!
    app_dirs = [Rails.root.join("app").to_s, Rails.root.join("lib").to_s]
    ObjectSpace.each_object(Class).select do |klass|
      next false unless klass < Sidekiq::Job && klass.name

      Object.const_source_location(klass.name)&.first&.start_with?(*app_dirs)
    end
  end

  it "finds the app's jobs" do
    expect(job_classes).to include(SendToElasticsearchWorker, DeleteUnusedPublicFilesJob)
  end

  it "has no job resolving a duplicate with :replace" do
    replacing = job_classes.select do |klass|
      on_conflict = klass.get_sidekiq_options["on_conflict"]
      Array.wrap(on_conflict.is_a?(Hash) ? on_conflict.values : on_conflict).any? { _1.to_s == "replace" }
    end

    message = "on_conflict: :replace walks the whole Sidekiq schedule set inside one Lua script whenever " \
              "the duplicate isn't queued, blocking Sidekiq Redis (#8712). Use :log, or a strategy that " \
              "doesn't scan, like SendToElasticsearchWorker's."
    expect(replacing.map(&:name)).to be_empty, message
  end
end
