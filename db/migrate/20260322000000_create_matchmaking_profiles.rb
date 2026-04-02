# frozen_string_literal: true

class CreateMatchmakingProfiles < ActiveRecord::Migration[7.0]
  def change
    create_table :matchmaking_profiles do |t|
      t.integer  :user_id, null: false

      # Identity (Hard-Filter fields)
      t.string   :gender                        # male, female
      t.string   :seeking_gender                 # male, female
      t.integer  :birth_year                     # for age calculation (not storing DOB for privacy)
      t.integer  :age_min_preference
      t.integer  :age_max_preference

      # Location (Hard-Filter + Soft-Score)
      t.string   :country
      t.string   :state
      t.string   :city
      t.string   :location_flexibility           # local_only, state, regional, national, international

      # Faith Foundation (Soft-Score + LLM-Evaluated)
      t.string   :denomination                   # baptist, reformed, non_denominational, catholic, pentecostal, methodist, presbyterian, lutheran, anglican, orthodox, church_of_christ, adventist, other
      t.string   :denomination_importance        # essential, preferred, flexible
      t.string   :church_attendance              # multiple_weekly, weekly, bi_weekly, monthly, occasional
      t.string   :baptism_status                 # baptized, not_yet, planning
      t.string   :bible_engagement               # daily, several_weekly, weekly, occasional
      t.text     :testimony                      # free-text faith journey (500 char max)

      # Theological Views (Soft-Score, flexible structured data)
      t.jsonb    :theological_views, default: {} # keys: spiritual_gifts, creation, gender_roles, end_times, salvation_security

      # Values and Goals (LLM-Evaluated + Soft-Score)
      t.string   :relationship_intention         # marriage_minded, exploring, friendship_first
      t.string   :children_preference            # want_children, have_and_want_more, have_done, open, no_children
      t.text     :life_goals                     # free-text (500 char max)
      t.text     :ministry_involvement           # free-text (500 char max)
      t.jsonb    :interests, default: []         # array of interest strings
      t.jsonb    :lifestyle, default: []         # array: no_alcohol, no_tobacco, fitness_active, homeschool_interest, etc.

      # Partner Preferences (LLM-Evaluated)
      t.text     :partner_description            # free-text ideal partner (500 char max)
      t.jsonb    :dealbreakers, default: []      # array of dealbreaker strings

      # System
      t.boolean  :active, default: true
      t.boolean  :visible, default: true         # can hide profile temporarily
      t.datetime :last_search_at
      t.timestamps
    end

    add_index :matchmaking_profiles, :user_id, unique: true
    add_index :matchmaking_profiles, %i[gender seeking_gender active], name: "idx_matchmaking_profiles_gender_seeking_active"
    add_index :matchmaking_profiles, :denomination
    add_index :matchmaking_profiles, :birth_year
    add_index :matchmaking_profiles, :state
  end
end
