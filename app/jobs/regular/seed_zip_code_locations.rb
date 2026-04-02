# frozen_string_literal: true

module Jobs
  class SeedZipCodeLocations < ::Jobs::Base
    sidekiq_options queue: "low"

    # Accepts both simplemaps uszips.csv format and a normalized format.
    # Simplemaps columns: zip, lat, lng, city, state_id, state_name, ...
    # Normalized columns: zip_code, latitude, longitude, city, state_abbr
    # Either filename works: uszips.csv or us_zip_codes.csv

    def execute(args = {})
      return if ZipCodeLocation.count > 30_000 # already seeded

      plugin_data_dir = File.join(File.dirname(__FILE__), "..", "..", "..", "data")

      csv_path = nil
      ["uszips.csv", "us_zip_codes.csv"].each do |name|
        candidate = File.join(plugin_data_dir, name)
        if File.exist?(candidate)
          csv_path = candidate
          break
        end
      end

      unless csv_path
        Rails.logger.warn(
          "[discourse-matchmaking] ZIP code CSV not found. " \
          "Place uszips.csv (from simplemaps.com) or us_zip_codes.csv " \
          "in the plugin's data/ directory."
        )
        return
      end

      Rails.logger.info("[discourse-matchmaking] Seeding ZIP code locations from #{csv_path}...")

      require "csv"
      count = 0
      batch = []
      batch_size = 1000

      CSV.foreach(csv_path, headers: true) do |row|
        # Handle both simplemaps and normalized column names
        zip = (row["zip"] || row["zip_code"]).to_s.strip.rjust(5, "0")
        lat = (row["lat"] || row["latitude"]).to_f
        lng = (row["lng"] || row["longitude"]).to_f
        city = (row["city"]).to_s.strip.presence
        state = (row["state_id"] || row["state_abbr"]).to_s.strip.presence

        next if zip.length != 5 || lat == 0.0 || lng == 0.0

        batch << {
          zip_code: zip,
          latitude: lat,
          longitude: lng,
          city: city,
          state_abbr: state,
        }

        if batch.size >= batch_size
          ZipCodeLocation.upsert_all(batch, unique_by: :zip_code)
          count += batch.size
          batch = []
        end
      end

      if batch.any?
        ZipCodeLocation.upsert_all(batch, unique_by: :zip_code)
        count += batch.size
      end

      Rails.logger.info("[discourse-matchmaking] Seeded #{count} ZIP code locations.")
    end
  end
end
