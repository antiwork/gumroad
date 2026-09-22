# frozen_string_literal: true

require "spec_helper"
require "active_record_proxy_adapters/mysql2_proxy"

# Real pool ownership, no stub of it: every model's pool belongs to ActiveRecord::Base
# (ApplicationRecord.primary_class? is true and both classes report the same connection descriptor),
# and that is the class mysql2_proxy compares a pin's klasses against. Stubbing `connection_class`
# to the class the pin was declared on is exactly what let this defect pass
# spec/config/mysql2_proxy_semantics_spec.rb while workers dropped dispute webhooks.
describe "ApplicationRecord.connected_to pins the pool owner" do
  let(:proxy) { ActiveRecordProxyAdapters::Mysql2Proxy.new(ActiveRecord::Base.connection) }

  around do |example|
    previous = ActiveRecordProxyAdapters::Contextualizer.current_context
    ActiveRecordProxyAdapters::Contextualizer.current_context = ActiveRecordProxyAdapters::Context.new({})
    allow(ApplicationRecord).to receive(:replica_roles_configured?).and_return(true)
    example.run
  ensure
    ActiveRecordProxyAdapters::Contextualizer.current_context = previous
  end

  def routed_role
    proxy.send(:roles_for, "SELECT * FROM purchases WHERE id = 1")
  end

  it "resolves the pool owner from the connection, not from the class holding the pin" do
    expect(proxy.send(:connection_class)).to eq(ActiveRecord::Base)
    expect(ApplicationRecord.connection.connection_descriptor.name).to eq(ActiveRecord::Base.name)
  end

  it "routes a read inside a :writing pin to the primary, and releases it after the block" do
    expect(routed_role).to eq([:reading])

    ApplicationRecord.connected_to(role: :writing) { expect(routed_role).to eq([:writing]) }

    expect(routed_role).to eq([:reading])
    expect(ActiveRecord::Base.connected_to_stack).to be_empty
  end

  it "lets the innermost pin win and restores the outer one" do
    ApplicationRecord.connected_to(role: :reading) do
      expect(routed_role).to eq([:reading])

      ApplicationRecord.connected_to(role: :writing) do
        expect(routed_role).to eq([:writing])
        ApplicationRecord.connected_to(role: :reading) { expect(routed_role).to eq([:reading]) }
        expect(routed_role).to eq([:writing])
      end

      expect(routed_role).to eq([:reading])
    end
  end

  it "pops the pin when the block raises" do
    expect do
      ApplicationRecord.connected_to(role: :writing) { raise "boom" }
    end.to raise_error("boom")

    expect(ActiveRecord::Base.connected_to_stack).to be_empty
    expect(routed_role).to eq([:reading])
  end

  # Web/Puma boot without the flag: no role is configured, so the pin has to stay the no-op it is
  # today rather than resolve a reading pool that does not exist.
  it "leaves the pin inert when no replica role is configured" do
    allow(ApplicationRecord).to receive(:replica_roles_configured?).and_return(false)

    ApplicationRecord.connected_to(role: :writing) { expect(routed_role).to eq([:reading]) }
  end
end
