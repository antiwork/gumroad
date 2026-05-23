# frozen_string_literal: true


shared_examples "a charge refund" do
context_ "#flow_of_funds" do
test "has a flow of funds" do
      expect(subject.flow_of_funds).to be_present
    end

test "has a flow of funds with a issued amount" do
      expect(subject.flow_of_funds.issued_amount).to be_present
    end

test "has a flow of funds with a settled amount" do
      expect(subject.flow_of_funds.settled_amount).to be_present
    end

test "has a flow of funds with a gumroad amount" do
      expect(subject.flow_of_funds.gumroad_amount).to be_present
    end
  end
end
