# frozen_string_literal: true

class AddVerificationToMatchmakingProfiles < ActiveRecord::Migration[7.0]
  def change
    add_column :matchmaking_profiles, :verification_status, :string, default: "unverified"
    add_column :matchmaking_profiles, :verification_data, :jsonb, default: {}
    add_column :matchmaking_profiles, :verification_conversation_topic_id, :integer
    add_column :matchmaking_profiles, :verified_at, :datetime
    add_column :matchmaking_profiles, :verified_by, :string
    add_index :matchmaking_profiles, :verification_status
  end
end
