# frozen_string_literal: true

class CreateMatchmakingConsents < ActiveRecord::Migration[7.0]
  def change
    create_table :matchmaking_consents do |t|
      t.integer  :user_id, null: false
      t.string   :consent_type, null: false      # profile_creation, ai_matching, llm_processing
      t.string   :policy_version, null: false
      t.boolean  :granted, null: false
      t.inet     :ip_address
      t.datetime :granted_at
      t.datetime :withdrawn_at
      t.timestamps
    end

    add_index :matchmaking_consents, %i[user_id consent_type], name: "idx_matchmaking_consents_user_type"
  end
end
