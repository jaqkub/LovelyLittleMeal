class Chat < ApplicationRecord
  belongs_to :user
  belongs_to :user_recipe
  has_many :messages
end
