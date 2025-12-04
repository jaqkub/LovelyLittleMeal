class Recipe < ApplicationRecord
  has_one :chat, dependent: :destroy
end
