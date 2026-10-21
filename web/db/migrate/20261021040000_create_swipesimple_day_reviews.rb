# frozen_string_literal: true

# Local review of one SwipeSimple business day. The digest ties the review to
# the export evidence it covered; a changed export invalidates it.
class CreateSwipesimpleDayReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :swipesimple_day_reviews do |t|
      t.references :tenant, type: :string, null: false, foreign_key: true
      t.date :business_date, null: false
      t.references :reviewed_by, null: false, foreign_key: { to_table: :users }
      t.datetime :reviewed_at, null: false
      t.string :reviewed_digest, null: false
      t.string :review_note, limit: 1000
      t.timestamps
    end
    add_index :swipesimple_day_reviews, %i[tenant_id business_date], unique: true
  end
end
