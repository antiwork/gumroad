# frozen_string_literal: true

require "test_helper"

class CsvSafeTest < ActiveSupport::TestCase
  test "preserves positive numeric strings" do
    csv = CsvSafe.generate { |c| c << ["+100", "+123.45", "+999"] }
    assert_equal "+100,+123.45,+999\n", csv
  end

  test "preserves negative numeric strings" do
    csv = CsvSafe.generate { |c| c << ["-100", "-123.45", "-999"] }
    assert_equal "-100,-123.45,-999\n", csv
  end

  test "preserves mixed numeric values" do
    csv = CsvSafe.generate { |c| c << ["-100", "+200", "300", "-1.5", "+2.75"] }
    assert_equal "-100,+200,300,-1.5,+2.75\n", csv
  end

  test "sanitizes formula injection with equals" do
    csv = CsvSafe.generate { |c| c << ["=1+1", "=SUM(A1:A10)", "=cmd|' /C calc'!A0"] }
    assert_equal "'=1+1,'=SUM(A1:A10),'=cmd|' /C calc'!A0\n", csv
  end

  test "sanitizes non-numeric strings starting with plus" do
    csv = CsvSafe.generate { |c| c << ["+abc", "+1+1", "+test"] }
    assert_equal "'+abc,'+1+1,'+test\n", csv
  end

  test "sanitizes non-numeric strings starting with minus" do
    csv = CsvSafe.generate { |c| c << ["-abc", "-1+1", "-test"] }
    assert_equal "'-abc,'-1+1,'-test\n", csv
  end

  test "sanitizes at-sign formulas" do
    csv = CsvSafe.generate { |c| c << ["@SUM(1+1)", "@A1"] }
    assert_equal "'@SUM(1+1),'@A1\n", csv
  end

  test "sanitizes tab and carriage return prefixes" do
    csv = CsvSafe.generate { |c| c << ["\t=1+1", "\r=1+1"] }
    assert_equal "'\t=1+1,\"'\r=1+1\"\n", csv
  end

  test "sanitizes pipe and percent prefixes" do
    csv = CsvSafe.generate { |c| c << ["|test", "%test"] }
    assert_equal "'|test,'%test\n", csv
  end

  test "preserves normal text without dangerous prefixes" do
    csv = CsvSafe.generate { |c| c << ["hello", "world", "123", "test@example.com"] }
    assert_equal "hello,world,123,test@example.com\n", csv
  end

  test "handles nil and empty values" do
    csv = CsvSafe.generate { |c| c << [nil, "", "test"] }
    assert_equal ",\"\",test\n", csv
  end

  test "preserves actual Numeric types" do
    csv = CsvSafe.generate { |c| c << [100, -200, 3.14, -5.67] }
    assert_equal "100,-200,3.14,-5.67\n", csv
  end

  test "handles edge cases with decimals" do
    csv = CsvSafe.generate { |c| c << ["+0.5", "-0.5", "+.5", "-.5"] }
    assert_equal "+0.5,-0.5,'+.5,'-.5\n", csv
  end

  test "sanitizes HYPERLINK attacks" do
    csv = CsvSafe.generate { |c| c << ['=HYPERLINK("http://attacker.invalid","click")'] }
    assert_equal "\"'=HYPERLINK(\"\"http://attacker.invalid\"\",\"\"click\"\")\"\n", csv
  end

  test "sanitizes DDE attacks" do
    csv = CsvSafe.generate { |c| c << ["=cmd|' /C calc'!A0", "=10+20+cmd|' /C calc'!A0"] }
    assert_equal "'=cmd|' /C calc'!A0,'=10+20+cmd|' /C calc'!A0\n", csv
  end

  test "handles mixed safe and dangerous values in same row" do
    csv = CsvSafe.generate do |c|
      c << ["normal", "+100", "-200", "=1+1", "@SUM()", "+abc", "test"]
    end
    assert_equal "normal,+100,-200,'=1+1,'@SUM(),'+abc,test\n", csv
  end

  test "CsvSafe.open sanitizes values when writing to file" do
    tempfile = Tempfile.new(["test", ".csv"])

    CsvSafe.open(tempfile.path, "w") do |csv|
      csv << ["+100", "-200", "=1+1", "normal"]
    end

    assert_equal "+100,-200,'=1+1,normal\n", File.read(tempfile.path)
  ensure
    tempfile&.close
    tempfile&.unlink
  end
end
