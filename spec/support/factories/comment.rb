# frozen_string_literal: true

FactoryBot.define do
  factory :comment do
    association :commentable, factory: :published_installment
    association :author, factory: :user
    author_name { author.display_name }
    comment_type { Comment::COMMENT_TYPE_USER_SUBMITTED }
    content { Faker::Quote.famous_last_words }
  end
end
