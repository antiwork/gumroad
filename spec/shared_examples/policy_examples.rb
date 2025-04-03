# frozen_string_literal: true

RSpec.shared_examples_for "an access-granting policy" do
  it "grants access" do
    seller_context = SellerContext.new(user: context_user, seller: context_seller)
    expect(subject).to permit(seller_context, record)
  end
end

RSpec.shared_examples_for "an access-granting policy for roles" do |access_roles|
  access_roles.each do |access_role|
    context "when the user is a #{access_role}" do
      let(:context_user) { send(access_role) }

      it_behaves_like "an access-granting policy"
    end
  end
end

RSpec.shared_examples_for "an access-denying policy" do
  it "denies access" do
    seller_context = SellerContext.new(user: context_user, seller: context_seller)
    expect(subject).not_to permit(seller_context, record)
  end
end

RSpec.shared_examples_for "an access-denying policy for roles" do |access_roles|
  access_roles.each do |access_role|
    context "when the user is a #{access_role}" do
      let(:context_user) { send(access_role) }

      it_behaves_like "an access-denying policy"
    end
  end
end
