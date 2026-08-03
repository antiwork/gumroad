# frozen_string_literal: true

require "spec_helper"

describe "taxonomy rake tasks" do
  before(:all) do
    # Re-loading a .rake file appends a second action to each task, which would make every
    # invocation run twice.
    unless Rake::Task.task_defined?("taxonomy:seed")
      Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
      load Rails.root.join("lib", "tasks", "taxonomy.rake")
    end
  end

  def run_task
    task = Rake::Task["taxonomy:seed"]
    task.reenable
    task.invoke
  end

  describe "taxonomy:seed" do
    let(:seeder) { instance_double(Taxonomy::Seeder) }

    before { allow(Taxonomy::Seeder).to receive(:new).and_return(seeder) }

    it "reports the created count on success" do
      allow(seeder).to receive(:perform).and_return(5)

      expect { run_task }.to output(/Created 5 taxonomy row\(s\)/).to_stdout
    end

    context "when seeding raises" do
      let(:error) { ActiveRecord::StatementInvalid.new("Lost connection to MySQL server") }

      before { allow(seeder).to receive(:perform).and_raise(error) }

      # The deploy script runs this with `|| echo`, so the shell throws the exit status away. If the
      # task swallows the failure too, a stale taxonomy tree ships with nothing anywhere to read.
      it "reports the failure to Sentry" do
        expect(ErrorNotifier).to receive(:notify).with(error, exclude_request_context: true, task: "taxonomy:seed")

        expect { run_task }.to raise_error(SystemExit).and output(/taxonomy:seed failed/).to_stderr
      end

      it "exits non-zero so a direct (non-deploy) run fails loudly" do
        allow(ErrorNotifier).to receive(:notify)

        expect { run_task }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      it "does not report the created count" do
        allow(ErrorNotifier).to receive(:notify)

        expect { expect { run_task }.to raise_error(SystemExit) }.to_not output(/Created/).to_stdout
      end
    end
  end
end
