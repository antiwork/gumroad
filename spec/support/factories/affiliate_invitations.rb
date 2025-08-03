 # frozen_string_literal: true

 FactoryBot.define do
   factory :affiliate_invitation do
     association :affiliate, factory: :direct_affiliate
   end
 end
