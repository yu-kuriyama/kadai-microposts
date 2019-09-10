class CreateFavorites < ActiveRecord::Migration[5.2]
  def change
    create_table :favorites do |t|
      t.references :user, foreign_key: true
      t.references :micropost, foreign_key: true

      t.timestamps
      t.index [:user_id, :micropost_id], unique: true
      #↑user_idとmicropost_idの組み合わせが重複して保存されないようにするため
    end
  end
end
