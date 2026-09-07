# frozen_string_literal: true

require "spec_helper"

describe "migrate_gumhead_to_flag_group" do
  before(:all) do
    unless Rake::Task.task_defined?("migrate_gumhead_to_flag_group")
      Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
      load Rails.root.join("lib", "tasks", "migrate_gumhead_to_flag_group.rake")
    end
  end

  def run_task
    task = Rake::Task["migrate_gumhead_to_flag_group"]
    task.reenable
    task.invoke
  end

  let(:actor_user) { create(:user) }
  let(:flagged_user) { create(:user, gumhead_enabled: true) }

  before do
    Feature.activate_user(:gumhead, actor_user)
    Feature.activate_user(:gumhead, flagged_user)
  end

  after do
    Flipper.disable_group(:gumhead, :gumhead_beta)
    Feature.deactivate(:gumhead)
  end

  it "converts actors to flag bits, enables the group, and clears the actors" do
    expect { run_task }.to output(/actors=2 bits_set=1 group_enabled=true actors_remaining=0/).to_stdout

    expect(actor_user.reload.gumhead_enabled?).to be(true)
    expect(flagged_user.reload.gumhead_enabled?).to be(true)
    expect(Flipper[:gumhead].enabled_groups).to include(Flipper.group(:gumhead_beta))
    expect(Flipper[:gumhead].actors_value).to be_empty
    expect(Feature.active?(:gumhead, actor_user)).to be(true)
    expect(Feature.active?(:gumhead, flagged_user)).to be(true)
  end

  it "is idempotent and never clears bits on a re-run" do
    run_task
    later_user = create(:user, gumhead_enabled: true)

    expect { run_task }.to output(/actors=0 bits_set=0 group_enabled=true actors_remaining=0/).to_stdout

    expect(actor_user.reload.gumhead_enabled?).to be(true)
    expect(later_user.reload.gumhead_enabled?).to be(true)
    expect(Feature.active?(:gumhead, later_user)).to be(true)
  end

  it "ignores actor entries that are not User ids" do
    Flipper.enable_actor(:gumhead, Flipper::Actor.new("Team;12"))

    expect { run_task }.not_to raise_error
    expect(Flipper[:gumhead].actors_value).to contain_exactly("Team;12")
  end
end
