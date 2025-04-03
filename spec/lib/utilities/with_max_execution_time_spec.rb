# frozen_string_literal: true

require "spec_helper"

describe WithMaxExecutionTime do
  describe ".timeout_queries" do
    it "raises Timeout error if query took longer than allowed" do
      # Note: MySQL max_execution_time ignores SLEEP(), so we have to manufacture a real slow query.
      create(:user)
      slow_query = "select * from users " + 50.times.map { |i| "join users u#{i}" }.join(" ")
      expect do
        described_class.timeout_queries(seconds: 0.001) do
          ActiveRecord::Base.connection.execute(slow_query)
        end
      end.to raise_error(described_class::QueryTimeoutError)
    end

    it "returns block value if no error occurred" do
      returned_value = described_class.timeout_queries(seconds: 5) do
        ActiveRecord::Base.connection.execute("select 1")
        :foo
      end
      expect(returned_value).to eq(:foo)
    end
  end
end
