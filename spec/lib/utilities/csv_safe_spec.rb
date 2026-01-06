# frozen_string_literal: true

require "spec_helper"

RSpec.describe CsvSafe do
  describe "CSV injection protection with numeric preservation" do
    it "preserves positive numeric strings" do
      csv = CsvSafe.generate { |csv| csv << ["+100", "+123.45", "+999"] }
      expect(csv).to eq("+100,+123.45,+999\n")
    end

    it "preserves negative numeric strings" do
      csv = CsvSafe.generate { |csv| csv << ["-100", "-123.45", "-999"] }
      expect(csv).to eq("-100,-123.45,-999\n")
    end

    it "preserves mixed numeric values" do
      csv = CsvSafe.generate { |csv| csv << ["-100", "+200", "300", "-1.5", "+2.75"] }
      expect(csv).to eq("-100,+200,300,-1.5,+2.75\n")
    end

    it "sanitizes formula injection with equals" do
      csv = CsvSafe.generate { |csv| csv << ["=1+1", "=SUM(A1:A10)", "=cmd|' /C calc'!A0"] }
      expect(csv).to eq("'=1+1,'=SUM(A1:A10),'=cmd|' /C calc'!A0\n")
    end

    it "sanitizes non-numeric strings starting with plus" do
      csv = CsvSafe.generate { |csv| csv << ["+abc", "+1+1", "+test"] }
      expect(csv).to eq("'+abc,'+1+1,'+test\n")
    end

    it "sanitizes non-numeric strings starting with minus" do
      csv = CsvSafe.generate { |csv| csv << ["-abc", "-1+1", "-test"] }
      expect(csv).to eq("'-abc,'-1+1,'-test\n")
    end

    it "sanitizes at-sign formulas" do
      csv = CsvSafe.generate { |csv| csv << ["@SUM(1+1)", "@A1"] }
      expect(csv).to eq("'@SUM(1+1),'@A1\n")
    end

    it "sanitizes tab and carriage return prefixes" do
      csv = CsvSafe.generate { |csv| csv << ["\t=1+1", "\r=1+1"] }
      expect(csv).to eq("'\t=1+1,\"'\r=1+1\"\n")
    end

    it "sanitizes pipe and percent prefixes" do
      csv = CsvSafe.generate { |csv| csv << ["|test", "%test"] }
      expect(csv).to eq("'|test,'%test\n")
    end

    it "preserves normal text without dangerous prefixes" do
      csv = CsvSafe.generate { |csv| csv << ["hello", "world", "123", "test@example.com"] }
      expect(csv).to eq("hello,world,123,test@example.com\n")
    end

    it "handles nil and empty values" do
      csv = CsvSafe.generate { |csv| csv << [nil, "", "test"] }
      expect(csv).to eq(",\"\",test\n")
    end

    it "preserves actual Numeric types" do
      csv = CsvSafe.generate { |csv| csv << [100, -200, 3.14, -5.67] }
      expect(csv).to eq("100,-200,3.14,-5.67\n")
    end

    it "handles edge cases with decimals" do
      csv = CsvSafe.generate { |csv| csv << ["+0.5", "-0.5", "+.5", "-.5"] }
      expect(csv).to eq("+0.5,-0.5,'+.5,'-.5\n")
    end

    it "sanitizes HYPERLINK attacks" do
      csv = CsvSafe.generate { |csv| csv << ['=HYPERLINK("http://attacker.invalid","click")'] }
      expect(csv).to eq("\"'=HYPERLINK(\"\"http://attacker.invalid\"\",\"\"click\"\")\"\n")
    end

    it "sanitizes DDE attacks" do
      csv = CsvSafe.generate { |csv| csv << ["=cmd|' /C calc'!A0", "=10+20+cmd|' /C calc'!A0"] }
      expect(csv).to eq("'=cmd|' /C calc'!A0,'=10+20+cmd|' /C calc'!A0\n")
    end

    it "handles mixed safe and dangerous values in same row" do
      csv = CsvSafe.generate do |csv|
        csv << ["normal", "+100", "-200", "=1+1", "@SUM()", "+abc", "test"]
      end
      expect(csv).to eq("normal,+100,-200,'=1+1,'@SUM(),'+abc,test\n")
    end
  end

  describe "CsvSafe.open" do
    it "sanitizes values when writing to file" do
      tempfile = Tempfile.new(["test", ".csv"])

      CsvSafe.open(tempfile.path, "w") do |csv|
        csv << ["+100", "-200", "=1+1", "normal"]
      end

      content = File.read(tempfile.path)
      expect(content).to eq("+100,-200,'=1+1,normal\n")

      tempfile.close
      tempfile.unlink
    end
  end
end
