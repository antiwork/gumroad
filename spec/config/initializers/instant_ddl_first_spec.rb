# frozen_string_literal: true

require "spec_helper"

describe InstantDdlFirst do
  # These run real DDL against the test database, because the whole value of this
  # initializer is what MySQL actually does with ALGORITHM=INSTANT -- a mocked
  # connection would only prove the mock agrees with the assumption.
  let(:connection) { ActiveRecord::Base.connection }
  let(:table) { "instant_ddl_first_probe" }

  before do
    connection.execute("DROP TABLE IF EXISTS #{table}")
    connection.execute(<<~SQL)
      CREATE TABLE #{table} (
        id BIGINT NOT NULL AUTO_INCREMENT,
        rating INT NOT NULL,
        PRIMARY KEY (id)
      ) ENGINE=InnoDB
    SQL
    connection.execute("INSERT INTO #{table} (rating) VALUES (5), (4), (3)")
  end

  after { connection.execute("DROP TABLE IF EXISTS #{table}") }

  def columns_of(name)
    connection.select_values(<<~SQL.squish)
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = DATABASE() AND table_name = '#{name}'
    SQL
  end

  describe "an ADD COLUMN, which is the case that never needed pt-osc" do
    it "applies it and reports that pt-osc can be skipped" do
      expect(described_class.attempt(table, "ADD COLUMN seller_notified_at datetime(6)")).to be(true)
      expect(columns_of(table)).to include("seller_notified_at")
    end

    it "leaves the existing rows alone" do
      described_class.attempt(table, "ADD COLUMN seller_notified_at datetime(6)")

      expect(connection.select_value("SELECT COUNT(*) FROM #{table}")).to eq(3)
      expect(connection.select_value("SELECT COUNT(*) FROM #{table} WHERE seller_notified_at IS NOT NULL")).to eq(0)
    end

    it "restores the session lock_wait_timeout it lowered" do
      before_value = connection.select_value("SELECT @@SESSION.lock_wait_timeout")

      described_class.attempt(table, "ADD COLUMN seller_notified_at datetime(6)")

      expect(connection.select_value("SELECT @@SESSION.lock_wait_timeout")).to eq(before_value)
    end
  end

  describe "an operation MySQL cannot do instantly" do
    it "falls back for ADD INDEX, without applying it" do
      expect(described_class.attempt(table, "ADD INDEX index_probe_on_rating (rating)")).to be(false)

      indexes = connection.select_values(<<~SQL.squish)
        SELECT DISTINCT index_name FROM information_schema.statistics
        WHERE table_schema = DATABASE() AND table_name = '#{table}'
      SQL
      expect(indexes).not_to include("index_probe_on_rating")
    end

    it "falls back for a column type change, leaving the column as it was" do
      expect(described_class.attempt(table, "MODIFY COLUMN rating BIGINT NOT NULL")).to be(false)

      type = connection.select_value(<<~SQL.squish)
        SELECT column_type FROM information_schema.columns
        WHERE table_schema = DATABASE() AND table_name = '#{table}' AND column_name = 'rating'
      SQL
      expect(type).to eq("int")
    end
  end

  describe "what it declines to attempt" do
    # A caller that already pinned an algorithm has said what it wants, and
    # appending a second ALGORITHM= would be invalid SQL.
    it "does not touch an ALTER that already specifies an algorithm" do
      expect(described_class.attempt(table, "ADD COLUMN a INT, ALGORITHM=COPY")).to be(false)
      expect(columns_of(table)).not_to include("a")
    end

    it "does not touch an ALTER that specifies a lock mode" do
      expect(described_class.attempt(table, "ADD COLUMN b INT, LOCK=NONE")).to be(false)
      expect(columns_of(table)).not_to include("b")
    end

    # One clause being instant-capable says nothing about the others, and a
    # partially applied multi-clause ALTER is the thing to avoid.
    it "does not touch a multi-clause ALTER" do
      expect(described_class.attempt(table, "ADD COLUMN c INT, ADD COLUMN d INT")).to be(false)
      expect(columns_of(table)).not_to include("c", "d")
    end
  end

  describe "an error that is not about instant-ness" do
    it "raises rather than silently falling back to pt-osc" do
      expect do
        described_class.attempt(table, "ADD COLUMN rating INT")
      end.to raise_error(ActiveRecord::StatementInvalid, /Duplicate column name/)
    end

    it "raises when the table does not exist" do
      expect do
        described_class.attempt("no_such_table_here", "ADD COLUMN e INT")
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe "the Alterity hook" do
    it "does not re-enter Alterity while running its own ALTER" do
      # Without Alterity.disable the ALTER would be intercepted by
      # Alterity#process_sql_query and sent straight back to pt-osc.
      expect(Alterity).to receive(:disable).and_call_original

      described_class.attempt(table, "ADD COLUMN seller_notified_at datetime(6)")
    end
  end
end
