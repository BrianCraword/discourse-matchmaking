# frozen_string_literal: true

class CreateMatchmakingMatches < ActiveRecord::Migration[7.0]
  def change
    create_table :matchmaking_matches do |t|
      t.integer  :searcher_id, null: false       # user who searched
      t.integer  :candidate_id, null: false      # user who was matched
      t.float    :compatibility_score            # 0.0-1.0 from scoring engine
      t.string   :status, default: "presented"   # presented, interested, mutual, dismissed
      t.text     :ai_explanation                 # the persona's explanation of why they matched
      t.timestamps
    end

    add_index :matchmaking_matches, %i[searcher_id candidate_id], unique: true, name: "idx_matchmaking_matches_searcher_candidate"
    add_index :matchmaking_matches, :candidate_id
    add_index :matchmaking_matches, :status
  end
end
