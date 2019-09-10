class Micropost < ApplicationRecord
  belongs_to :user
  
  validates :content, presence: true, length: { maximum: 255 }
  
  #お気に入り
  has_many :favorites, foreign_key: 'micropost_id'
   has_many :users, through: :favorites
end
