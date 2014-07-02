class CreateStartEnds < ActiveRecord::Migration
  def change
    create_table :start_ends do |t|
      t.integer :user_id
      t.date :startday
      t.time :start_1
      t.time :start_2
      t.time :start_3
      t.time :start_4
      t.time :start_5
      t.time :start_6
      t.time :start_7
      t.time :end_1
      t.time :end_2
      t.time :end_3
      t.time :end_4
      t.time :end_5
      t.time :end_6
      t.time :end_7
      t.time :pause_1
      t.time :pause_2
      t.time :pause_3
      t.time :pause_4
      t.time :pause_5
      t.time :pause_6
      t.time :pause_7
    end
    add_index :start_ends, :user_id
    add_index :start_ends, :startday
  end
end
