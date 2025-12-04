class Chat < ApplicationRecord
  belongs_to :user
  belongs_to :recipe
  has_many :messages, dependent: :destroy
end
