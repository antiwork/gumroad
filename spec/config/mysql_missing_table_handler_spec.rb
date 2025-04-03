# frozen_string_literal: true

require "spec_helper"

describe "MySQL missing table handler" do
  before(:all) do
    @connection = ActiveRecord::Base.connection
    @connection.execute("create table foo (id int)")
    @connection.execute("insert into foo(id) values (1),(2),(3)")
  end

  after(:all) do
    @connection.execute("drop table if exists foo, bar")
  end

  it "retries query if table is missing" do
    @connection.execute("rename table foo to bar")

    Thread.new do
      sleep 2
      ActiveRecord::Base.connection.execute("rename table bar to foo")
    end

    expect do
      result = @connection.execute("select * from foo")
      expect(result.to_a.flatten).to match_array([1, 2, 3])
    end.not_to raise_error
  end
end
