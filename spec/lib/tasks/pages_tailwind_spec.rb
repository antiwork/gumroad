# frozen_string_literal: true

require "spec_helper"

describe "pages_tailwind rake tasks" do
  before(:all) do
    # Re-loading a .rake file appends a second action to each task, which would make every
    # invocation run twice.
    load Rails.root.join("lib", "tasks", "pages_tailwind.rake") unless Rake::Task.task_defined?("pages_tailwind:build")
  end

  # The task's block runs with the top-level object as self, which is where Rake's `sh` lives.
  let(:rake_main) { TOPLEVEL_BINDING.receiver }

  def run_task
    task = Rake::Task["pages_tailwind:build"]
    task.reenable
    task.invoke
  end

  before { allow(rake_main).to receive(:sh) }

  describe "pages_tailwind:build" do
    it "builds the pages CSS" do
      run_task

      expect(rake_main).to have_received(:sh).with("npm run build:pages-tailwind")
    end

    it "skips the build when the production compile restored it from the cache" do
      stub_const("ENV", ENV.to_h.merge("PAGES_TAILWIND_RESTORED" => "true"))

      run_task

      expect(rake_main).not_to have_received(:sh)
    end
  end
end
