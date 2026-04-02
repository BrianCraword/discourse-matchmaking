# frozen_string_literal: true

class AddFaithInsightToMatchmakingProfiles < ActiveRecord::Migration[7.0]
  def change
    add_column :matchmaking_profiles, :faith_tags, :jsonb, default: {}
    add_column :matchmaking_profiles, :faith_summary, :text
    add_column :matchmaking_profiles, :faith_insight_updated_at, :datetime
  end
end
