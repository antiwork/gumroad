# frozen_string_literal: true

require "spec_helper"
require "active_record_proxy_adapters/mysql2_proxy"

# Every model's pool belongs to ActiveRecord::Base — the class mysql2_proxy compares a pin's klasses
# against — so the pin is only effective if it names that owner; stubbing `connection_class` to the
# pin's own class passed while workers dropped webhook events.
#
# No reading role is configured in this boot, so routing is measured against each example's unpinned
# baseline and the worker-replica effect is shown by the PR-body transcript.
describe "ApplicationRecord.connected_to pins the pool owner" do
  let(:routing_proxy) { ActiveRecordProxyAdapters::Mysql2Proxy.new(ActiveRecord::Base.connection) }

  # The pin's delegating branch only exists with the worker flag at boot.
  before { allow(ApplicationRecord).to receive(:replica_roles_configured?).and_return(true) }

  # Not `proxy`: Billy::RspecHelper defines and resets that name.
  def routed_role
    routing_proxy.send(:roles_for, "SELECT * FROM purchases WHERE id = 1")
  end

  it "resolves the pool owner from the connection, not from the class holding the pin" do
    expect(routing_proxy.send(:connection_class)).to eq(ActiveRecord::Base)
    expect(ApplicationRecord.connection.connection_descriptor.name).to eq(ActiveRecord::Base.name)
    expect(ApplicationRecord.connected_to_stack).to be_empty
  end

  it "pushes the pin on the pool owner, keeps it across a nested pin, and pops it after the block" do
    unpinned = routed_role

    ApplicationRecord.connected_to(role: :writing) do
      expect(ActiveRecord::Base.connected_to_stack.last[:klasses]).to eq([ActiveRecord::Base])
      expect(routed_role).to eq([:writing])

      ApplicationRecord.connected_to(role: :writing, prevent_writes: true) do
        expect(ActiveRecord::Base.connected_to_stack.last[:klasses]).to eq([ActiveRecord::Base])
        expect(ActiveRecord::Base.current_preventing_writes).to eq(true)
      end

      expect(ActiveRecord::Base.connected_to_stack.length).to eq(1)
      expect(ActiveRecord::Base.current_preventing_writes).to eq(false)
      expect(routed_role).to eq([:writing])
    end

    expect(ActiveRecord::Base.connected_to_stack).to be_empty
    expect(routed_role).to eq(unpinned)
  end

  it "pops the pin when the block raises" do
    unpinned = routed_role

    expect do
      ApplicationRecord.connected_to(role: :writing) { raise "boom" }
    end.to raise_error("boom")

    expect(ActiveRecord::Base.connected_to_stack).to be_empty
    expect(routed_role).to eq(unpinned)
  end

  # Web/Puma boot without the flag: no reading role is configured, so the pin has to stay the no-op it
  # is today rather than resolve a pool that does not exist.
  context "without replica roles configured" do
    before { allow(ApplicationRecord).to receive(:replica_roles_configured?).and_return(false) }

    it "leaves the pin inert" do
      unpinned = routed_role

      ApplicationRecord.connected_to(role: :writing) do
        expect(ActiveRecord::Base.connected_to_stack.last[:klasses]).to eq([ApplicationRecord])
        expect(routed_role).to eq(unpinned)
      end
    end
  end
end
