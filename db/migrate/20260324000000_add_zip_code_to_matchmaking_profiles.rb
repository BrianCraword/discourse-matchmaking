# frozen_string_literal: true

class AddZipCodeToMatchmakingProfiles < ActiveRecord::Migration[7.0]
  def change
    add_column :matchmaking_profiles, :zip_code, :string
    add_index :matchmaking_profiles, :zip_code
  end
end
