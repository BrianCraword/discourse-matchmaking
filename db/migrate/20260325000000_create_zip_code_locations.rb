# frozen_string_literal: true

class CreateZipCodeLocations < ActiveRecord::Migration[7.0]
  def change
    create_table :zip_code_locations do |t|
      t.string :zip_code, null: false, limit: 5
      t.float  :latitude, null: false
      t.float  :longitude, null: false
      t.string :city, limit: 100
      t.string :state_abbr, limit: 2
    end

    add_index :zip_code_locations, :zip_code, unique: true
    add_index :zip_code_locations, [:latitude, :longitude]
    add_index :zip_code_locations, :state_abbr
  end
end
